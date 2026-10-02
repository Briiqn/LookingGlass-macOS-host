/**
 * Looking Glass
 * Copyright © 2017-2026 The Looking Glass Authors
 * https://looking-glass.io
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 2 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc., 59
 * Temple Place, Suite 330, Boston, MA 02111-1307 USA
 */

// LGMP side of the KVMFR clipboard, adapted from the Windows IDD's
// CLGMPClipboardTransport. On Windows the transport lives in the display
// driver and relays to a separate Helper process; here the OS clipboard
// (the "Helper") is in the same process and runs on the same thread, so the
// BUSY/retry relaying between the two disappears. The wire protocol, owner
// lease and validation rules are unchanged.

#include "clipboard.h"
#include "interface/platform.h"

#include "common/debug.h"
#include "common/thread.h"
#include "common/time.h"

#include "lgmp/stream.h"
#include <LGProtocol/LGMPConfig.h>

#include <stdatomic.h>
#include <string.h>

#define OWNER_LEASE_MS     1000
#define DRAIN_TIMEOUT_MS   1000
#define MEMORY_COUNT       KVMFR_CLIPBOARD_STREAM_SLOT_COUNT
#define STREAM_DRAIN_MAX   64
#define ENDPOINT_GENERATION 1

static const struct LGMPQueueConfig CLIPBOARD_QUEUE_CONFIG =
{
  .queueID     = LGMP_Q_CLIPBOARD,
  .numMessages = LGMP_Q_CLIPBOARD_LEN,
  .subTimeout  = 1000
};

static struct
{
  PLGMPHostQueue   queue;
  PLGMPHostStream  hostToClient;
  PLGMPHostStream  clientToHost;
  PLGMPMemory      statusMemory [MEMORY_COUNT];
  PLGMPMemory      messageMemory[MEMORY_COUNT];
  KVMFRStreamDescriptor hostToClientDesc;
  KVMFRStreamDescriptor clientToHostDesc;

  LGThread  * thread;
  atomic_bool stop;

  uint32_t endpointGeneration;
  bool     statusDirty;
  uint32_t statusSerial;
  uint32_t messageSerial;

  uint32_t ownerClientID;
  uint32_t ownerGeneration;
  uint64_t ownerDeadline;     // ms
  bool     ownerReleasing;
  uint64_t releaseDeadline;   // ms
  const char * releaseReason;
  bool     replayPending;

  // latest OFFER/CLEAR from this side, replayed to each new owner
  bool                  cachedValid;
  KVMFRClipboardMessage cached;
  uint32_t              hostFormats;
}
this;

static inline uint32_t seqNext(uint32_t value)
{
  const uint32_t next = value + 1;
  return next ? next : 1;
}

static inline uint64_t nowMs(void)
{
  return microtime() / 1000;
}

static KVMFRStreamDescriptor toWire(const struct LGMPStreamDescriptor * d)
{
  KVMFRStreamDescriptor w =
  {
    .magic      = d->magic,
    .version    = d->version,
    .size       = d->size,
    .offset     = d->offset,
    .regionSize = d->regionSize,
    .direction  = d->direction,
    .policy     = d->policy,
    .slotCount  = d->slotCount,
    .slotSize   = d->slotSize
  };
  return w;
}

static bool emptyControl(const KVMFRClipboardMessage * m, bool keepToken)
{
  return !m->clipboardGeneration && !m->transfer && !m->offset && !m->size &&
    !m->format && !m->flags && (keepToken || !m->token) && !m->length &&
    !m->sequence;
}

static bool validOffer(const KVMFRClipboardMessage * m)
{
  return m->clipboardGeneration && m->token &&
    !(m->token & ~KVMFR_CLIPBOARD_FORMAT_MASK_ALL) &&
    !m->transfer && !m->offset && !m->size && !m->format && !m->flags &&
    !m->length && !m->sequence;
}

static bool validClear(const KVMFRClipboardMessage * m)
{
  return m->clipboardGeneration && !m->token && !m->transfer && !m->offset &&
    !m->size && !m->format && !m->flags && !m->length && !m->sequence;
}

static bool validClientRequest(const KVMFRClipboardMessage * m)
{
  return m->clipboardGeneration &&
    kvmfrClipboardTransferFromClient(m->transfer) &&
    kvmfrClipboardRepresentationFormatValid(m->format) &&
    !m->offset && !m->size && !m->flags && !m->token && !m->length &&
    !m->sequence;
}

static bool validCancel(const KVMFRClipboardMessage * m)
{
  return m->transfer && !m->offset && !m->size &&
    (!m->format || kvmfrClipboardRepresentationFormatValid(m->format)) &&
    !m->flags && !m->length && !m->sequence;
}

static bool ownerSubscribed(void)
{
  if (!this.ownerClientID)
    return false;

  uint32_t clients[LGMP_MAX_CLIENTS] = { 0 };
  unsigned count = 0;
  if (lgmpHostGetClientIDs(this.queue, clients, &count) != LGMP_OK)
    return false;
  for (unsigned i = 0; i < count; ++i)
    if (clients[i] == this.ownerClientID)
      return true;
  return false;
}

static void renewLease(void)
{
  this.ownerDeadline = nowMs() + OWNER_LEASE_MS;
}

static bool bindStreams(uint32_t clientID)
{
  LGMP_STATUS status = lgmpHostStreamBind(this.hostToClient, clientID, NULL);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("Failed to bind the host-to-client clipboard stream: %s",
        lgmpStatusString(status));
    return false;
  }

  status = lgmpHostStreamBind(this.clientToHost, clientID, NULL);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("Failed to bind the client-to-host clipboard stream: %s",
        lgmpStatusString(status));
    lgmpHostStreamUnbind(this.hostToClient);
    return false;
  }
  return true;
}

static bool tryUnbindStreams(void)
{
  bool complete = true;
  PLGMPHostStream streams[] = { this.clientToHost, this.hostToClient };
  for (unsigned i = 0; i < 2; ++i)
  {
    if (!streams[i])
      continue;
    const LGMP_STATUS status = lgmpHostStreamUnbind(streams[i]);
    if (status == LGMP_ERR_STREAM_BUSY)
      complete = false;
    else if (status != LGMP_OK && status != LGMP_ERR_STREAM_UNBOUND)
      DEBUG_WARN("lgmpHostStreamUnbind Failed (Clipboard): %s",
          lgmpStatusString(status));
  }
  return complete;
}

static void forceUnbindStreams(void)
{
  if (this.clientToHost)
    lgmpHostStreamForceUnbind(this.clientToHost);
  if (this.hostToClient)
    lgmpHostStreamForceUnbind(this.hostToClient);
}

static void finishOwnerRelease(void)
{
  if (!this.ownerClientID)
    return;

  DEBUG_INFO("Clipboard owner %u released (%s)", this.ownerClientID,
      this.releaseReason ? this.releaseReason : "unspecified");

  this.ownerClientID   = 0;
  this.ownerGeneration = 0;
  this.ownerReleasing  = false;
  this.releaseReason   = NULL;
  this.ownerDeadline   = 0;
  this.replayPending   = false;
  this.statusDirty     = true;
  os_clipboardOwnerChanged(false);
}

static void releaseOwner(const char * reason, bool force)
{
  if (!this.ownerClientID)
    return;

  if (!this.ownerReleasing)
  {
    this.ownerReleasing  = true;
    this.releaseReason   = reason;
    this.releaseDeadline = nowMs() + DRAIN_TIMEOUT_MS;
    this.replayPending   = false;
  }

  if (force)
  {
    forceUnbindStreams();
    finishOwnerRelease();
    return;
  }

  if (tryUnbindStreams())
    finishOwnerRelease();
}

static void retryOwnerRelease(void)
{
  if (!this.ownerReleasing)
    return;

  if (nowMs() >= this.releaseDeadline)
  {
    DEBUG_WARN("Timed out draining the clipboard streams, discarding");
    forceUnbindStreams();
    finishOwnerRelease();
    return;
  }

  if (tryUnbindStreams())
    finishOwnerRelease();
}

static PLGMPMemory findAvailable(PLGMPMemory * memory)
{
  for (unsigned i = 0; i < MEMORY_COUNT; ++i)
    if (memory[i] && !lgmpHostQueuePayloadPending(this.queue, memory[i]))
      return memory[i];
  return NULL;
}

// posts a control message to the owner only
static ClipboardSendResult postToOwner(const KVMFRClipboardMessage * record)
{
  if (!this.ownerClientID || this.ownerReleasing)
    return CLIPBOARD_NO_OWNER;

  PLGMPMemory memory = findAvailable(this.messageMemory);
  if (!memory)
    return CLIPBOARD_BUSY;

  KVMFRClipboardMessage message = *record;
  message.version    = KVMFR_CLIPBOARD_VERSION;
  message.generation = this.ownerGeneration;
  memcpy(lgmpHostMemPtr(memory), &message, sizeof(message));

  const uint32_t serial = seqNext(this.messageSerial);
  unsigned recipients = 0;
  const uint32_t clientID = this.ownerClientID;
  const LGMP_STATUS status = lgmpHostQueuePostForClients(this.queue,
      KVMFR_CLIPBOARD_QUEUE_UDATA(KVMFR_CLIPBOARD_QUEUE_MESSAGE, serial),
      memory, &clientID, 1, &recipients);

  if (status == LGMP_ERR_QUEUE_FULL)
    return CLIPBOARD_BUSY;
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostQueuePostForClients Failed (Clipboard): %s",
        lgmpStatusString(status));
    releaseOwner("queue post failed", true);
    return CLIPBOARD_NO_OWNER;
  }
  if (!recipients)
  {
    releaseOwner("subscriber disappeared", true);
    return CLIPBOARD_NO_OWNER;
  }

  this.messageSerial = serial;
  return CLIPBOARD_SENT;
}

ClipboardSendResult clipboardHost_sendControl(KVMFRClipboardMessage * record)
{
  record->version = KVMFR_CLIPBOARD_VERSION;

  if (record->type == KVMFR_CLIPBOARD_MESSAGE_OFFER ||
      record->type == KVMFR_CLIPBOARD_MESSAGE_CLEAR)
  {
    this.cached      = *record;
    this.cachedValid = true;
    this.hostFormats = record->type == KVMFR_CLIPBOARD_MESSAGE_OFFER ?
      record->token : 0;
    this.statusDirty = true;

    if (!this.ownerClientID || this.ownerReleasing)
      return CLIPBOARD_SENT; // replayed to the next owner

    const ClipboardSendResult result = postToOwner(record);
    if (result == CLIPBOARD_BUSY)
      this.replayPending = true;
    else
      this.replayPending = false;
    return CLIPBOARD_SENT;
  }

  return postToOwner(record);
}

ClipboardSendResult clipboardHost_sendStream(KVMFRClipboardMessage * record,
    const void * data)
{
  if (!this.ownerClientID || this.ownerReleasing)
    return CLIPBOARD_NO_OWNER;

  KVMFRClipboardMessage message = *record;
  message.version    = KVMFR_CLIPBOARD_VERSION;
  message.generation = this.ownerGeneration;

  LGMPStreamBuffer buffer = { 0 };
  LGMP_STATUS status = lgmpHostStreamWriteAcquire(this.hostToClient, &buffer);
  if (status == LGMP_ERR_STREAM_FULL)
    return CLIPBOARD_BUSY;
  if (status == LGMP_ERR_STREAM_UNBOUND || status == LGMP_ERR_STREAM_STALE)
  {
    releaseOwner("clipboard stream binding lost", false);
    return CLIPBOARD_NO_OWNER;
  }
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostStreamWriteAcquire Failed (Clipboard): %s",
        lgmpStatusString(status));
    releaseOwner("stream write failed", true);
    return CLIPBOARD_NO_OWNER;
  }

  const uint32_t bytes = sizeof(message) + message.length;
  if (!buffer.data || buffer.capacity < bytes)
  {
    lgmpHostStreamWriteCancel(this.hostToClient, &buffer);
    DEBUG_ERROR("Clipboard stream slot too small: %u < %u",
        buffer.capacity, bytes);
    return CLIPBOARD_NO_OWNER;
  }

  memcpy(buffer.data, &message, sizeof(message));
  if (message.length)
    memcpy((uint8_t *)buffer.data + sizeof(message), data, message.length);

  status = lgmpHostStreamWriteCommit(this.hostToClient, &buffer, bytes);
  if (status != LGMP_OK)
  {
    releaseOwner("clipboard stream commit failed", false);
    return CLIPBOARD_NO_OWNER;
  }
  return CLIPBOARD_SENT;
}

bool clipboardHost_hasOwner(void)
{
  return this.ownerClientID && !this.ownerReleasing;
}

static bool publishStatus(void)
{
  if (lgmpHostQueueNewSubs(this.queue))
    this.statusDirty = true;
  if (!this.statusDirty)
    return true;

  uint32_t clients[LGMP_MAX_CLIENTS] = { 0 };
  unsigned clientCount = 0;
  LGMP_STATUS status = lgmpHostGetClientIDs(this.queue, clients, &clientCount);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostGetClientIDs Failed (Clipboard): %s",
        lgmpStatusString(status));
    return false;
  }
  if (!clientCount)
    return true;

  PLGMPMemory memory = findAvailable(this.statusMemory);
  if (!memory)
    return true;

  KVMFRClipboardStatus st = { 0 };
  st.version         = KVMFR_CLIPBOARD_VERSION;
  st.flags           = KVMFR_CLIPBOARD_STATUS_AVAILABLE;
  st.generation      = this.endpointGeneration;
  st.lease           = OWNER_LEASE_MS;
  st.formats         = this.hostFormats;
  st.slotBytes       = KVMFR_CLIPBOARD_DATA_BYTES;
  st.streamVersion   = KVMFR_CLIPBOARD_STREAM_VERSION;
  st.streamSlotCount = KVMFR_CLIPBOARD_STREAM_SLOT_COUNT;
  st.hostToClient    = this.hostToClientDesc;
  st.clientToHost    = this.clientToHostDesc;
  if (this.ownerClientID && !this.ownerReleasing)
  {
    st.flags          |= KVMFR_CLIPBOARD_STATUS_HAS_OWNER;
    st.ownerClientID   = this.ownerClientID;
    st.ownerGeneration = this.ownerGeneration;
  }
  memcpy(lgmpHostMemPtr(memory), &st, sizeof(st));

  const uint32_t serial = seqNext(this.statusSerial);
  unsigned recipients = 0;
  status = lgmpHostQueuePostForClients(this.queue,
      KVMFR_CLIPBOARD_QUEUE_UDATA(KVMFR_CLIPBOARD_QUEUE_STATUS, serial),
      memory, clients, clientCount, &recipients);
  if (status == LGMP_ERR_QUEUE_FULL)
    return true;
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostQueuePostForClients Failed (Clipboard status): %s",
        lgmpStatusString(status));
    return false;
  }
  if (recipients)
  {
    this.statusSerial = serial;
    this.statusDirty  = false;
  }
  return true;
}

static void replayClipboard(void)
{
  if (!this.replayPending || !this.ownerClientID || this.ownerReleasing)
    return;
  if (!this.cachedValid)
  {
    this.replayPending = false;
    return;
  }
  if (postToOwner(&this.cached) != CLIPBOARD_BUSY)
    this.replayPending = false;
}

static bool validClaim(const KVMFRClipboardMessage * m)
{
  return m->version == KVMFR_CLIPBOARD_VERSION &&
    m->generation && m->token == this.endpointGeneration &&
    emptyControl(m, true);
}

static bool validOwnedControl(const KVMFRClipboardMessage * m)
{
  if (m->version != KVMFR_CLIPBOARD_VERSION ||
      m->generation != this.ownerGeneration)
    return false;

  if (kvmfrClipboardFileMessageType(m->type))
    return kvmfrClipboardFileMessageValid(m) &&
      m->type != KVMFR_CLIPBOARD_MESSAGE_FILE_DATA;

  switch (m->type)
  {
    case KVMFR_CLIPBOARD_MESSAGE_RELEASE:
    case KVMFR_CLIPBOARD_MESSAGE_KEEPALIVE:
      return emptyControl(m, false);
    case KVMFR_CLIPBOARD_MESSAGE_OFFER:
      return validOffer(m);
    case KVMFR_CLIPBOARD_MESSAGE_CLEAR:
      return validClear(m);
    case KVMFR_CLIPBOARD_MESSAGE_REQUEST:
      return validClientRequest(m);
    case KVMFR_CLIPBOARD_MESSAGE_CANCEL:
      return validCancel(m);
    default:
      return false;
  }
}

static void processMessage(uint32_t clientID, const KVMFRClipboardMessage * m)
{
  if (m->type == KVMFR_CLIPBOARD_MESSAGE_CLAIM)
  {
    if (!validClaim(m))
      return;

    if (this.ownerClientID)
    {
      if (!this.ownerReleasing && this.ownerClientID == clientID &&
          this.ownerGeneration == m->generation)
        renewLease();
      return;
    }

    if (!bindStreams(clientID))
      return;

    this.ownerClientID   = clientID;
    this.ownerGeneration = m->generation;
    renewLease();
    this.statusDirty   = true;
    this.replayPending = this.cachedValid;
    DEBUG_INFO("Clipboard owner %u acquired", clientID);
    os_clipboardOwnerChanged(true);
    return;
  }

  if (this.ownerClientID != clientID || this.ownerReleasing ||
      m->generation != this.ownerGeneration)
    return;

  if (!validOwnedControl(m))
  {
    releaseOwner("invalid clipboard message", false);
    return;
  }

  renewLease();
  switch (m->type)
  {
    case KVMFR_CLIPBOARD_MESSAGE_KEEPALIVE:
      return;

    case KVMFR_CLIPBOARD_MESSAGE_RELEASE:
      releaseOwner("client release", false);
      return;

    default:
      os_clipboardMessage(m);
      return;
  }
}

static bool drainMessages(void)
{
  for (unsigned count = 0; count < 64; ++count)
  {
    uint8_t  data[LGMP_MSGS_SIZE];
    size_t   size     = 0;
    uint32_t clientID = 0;
    const LGMP_STATUS status = lgmpHostReadDataWithSource(this.queue, data,
        &size, &clientID);
    if (status == LGMP_ERR_QUEUE_EMPTY)
      return true;
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostReadDataWithSource Failed (Clipboard): %s",
          lgmpStatusString(status));
      return false;
    }

    if (size == sizeof(KVMFRClipboardMessage))
    {
      KVMFRClipboardMessage message;
      memcpy(&message, data, sizeof(message));
      processMessage(clientID, &message);
    }
    else if (clientID == this.ownerClientID)
      releaseOwner("invalid clipboard message size", false);

    const LGMP_STATUS ack = lgmpHostAckData(this.queue);
    if (ack != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostAckData Failed (Clipboard): %s",
          lgmpStatusString(ack));
      return false;
    }
  }
  return true;
}

static bool drainStream(bool * received)
{
  *received = false;
  if (!this.ownerClientID || !this.clientToHost)
    return true;

  for (unsigned drained = 0; drained < STREAM_DRAIN_MAX; ++drained)
  {
    LGMPStreamBuffer buffer = { 0 };
    LGMP_STATUS status = lgmpHostStreamReadPeek(this.clientToHost, &buffer);
    if (status == LGMP_ERR_STREAM_EMPTY)
      break;
    if (status == LGMP_ERR_STREAM_UNBOUND || status == LGMP_ERR_STREAM_STALE)
    {
      if (!this.ownerReleasing)
        releaseOwner("clipboard stream binding lost", false);
      break;
    }
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostStreamReadPeek Failed (Clipboard): %s",
          lgmpStatusString(status));
      return false;
    }
    *received = true;

    KVMFRClipboardMessage record = { 0 };
    if (buffer.data && buffer.size >= sizeof(record))
      memcpy(&record, buffer.data, sizeof(record));

    const bool valid = buffer.data &&
      buffer.size == sizeof(record) + record.length &&
      record.version == KVMFR_CLIPBOARD_VERSION &&
      record.generation == this.ownerGeneration &&
      (record.type == KVMFR_CLIPBOARD_MESSAGE_DATA ||
       (record.type == KVMFR_CLIPBOARD_MESSAGE_FILE_DATA &&
        kvmfrClipboardFileMessageValid(&record))) &&
      record.length <= KVMFR_CLIPBOARD_DATA_BYTES &&
      !(record.flags & ~(KVMFR_CLIPBOARD_FLAG_BEGIN |
        KVMFR_CLIPBOARD_FLAG_END)) &&
      record.offset <= UINT64_MAX - record.length;

    // stream records after an owner release only finish draining
    if (valid && !this.ownerReleasing)
    {
      renewLease();
      os_clipboardStreamData(&record,
          (const uint8_t *)buffer.data + sizeof(record));
    }

    status = lgmpHostStreamReadRelease(this.clientToHost, &buffer);
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostStreamReadRelease Failed (Clipboard): %s",
          lgmpStatusString(status));
      return false;
    }

    if (!valid && !this.ownerReleasing)
    {
      releaseOwner("invalid clipboard stream record", false);
      break;
    }
  }
  return true;
}

static int clipboardThread(void * opaque)
{
  LGMPStreamPollState poll;
  const struct LGMPStreamPollConfig pollConfig =
  {
    .spinCount = 32,
    .minWaitUs = 50,
    .maxWaitUs = 1000
  };
  if (lgmpStreamPollInit(&poll, pollConfig) != LGMP_OK)
    return 1;

  os_clipboardStart();

  while (!atomic_load(&this.stop))
  {
    if (this.ownerClientID && !this.ownerReleasing && !ownerSubscribed())
      releaseOwner("subscriber disappeared", true);
    else if (this.ownerClientID && !this.ownerReleasing &&
        nowMs() >= this.ownerDeadline)
      releaseOwner("lease expired", false);

    bool received = false;
    if (!drainMessages() || !drainStream(&received) || !publishStatus())
      break;

    retryOwnerRelease();
    replayClipboard();
    os_clipboardTick();

    if (received)
      lgmpStreamPollActivity(&poll);

    uint32_t waitUs = 50000;
    if (this.ownerClientID)
      waitUs = lgmpStreamPollIdle(&poll);
    if (waitUs)
      nsleep((uint64_t)waitUs * 1000);
  }

  releaseOwner("transport stopped", true);
  os_clipboardStop();
  return 0;
}

bool clipboardHost_setup(PLGMPHost host)
{
  LGMP_STATUS status = lgmpHostQueueNew(host, CLIPBOARD_QUEUE_CONFIG,
      &this.queue);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostQueueNew Failed (Clipboard): %s",
        lgmpStatusString(status));
    return false;
  }

  for (unsigned i = 0; i < MEMORY_COUNT; ++i)
  {
    if (lgmpHostMemAlloc(host, sizeof(KVMFRClipboardStatus),
          &this.statusMemory[i]) != LGMP_OK ||
        lgmpHostMemAlloc(host, sizeof(KVMFRClipboardMessage),
          &this.messageMemory[i]) != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostMemAlloc Failed (Clipboard)");
      clipboardHost_free();
      return false;
    }
    memset(lgmpHostMemPtr(this.statusMemory [i]), 0,
        sizeof(KVMFRClipboardStatus));
    memset(lgmpHostMemPtr(this.messageMemory[i]), 0,
        sizeof(KVMFRClipboardMessage));
  }

  const struct LGMPStreamConfig toClient =
  {
    .direction = LGMP_STREAM_HOST_TO_CLIENT,
    .policy    = LGMP_STREAM_RELIABLE_FIFO,
    .slotCount = KVMFR_CLIPBOARD_STREAM_SLOT_COUNT,
    .slotSize  = KVMFR_CLIPBOARD_STREAM_RECORD_BYTES
  };
  const struct LGMPStreamConfig toHost =
  {
    .direction = LGMP_STREAM_CLIENT_TO_HOST,
    .policy    = LGMP_STREAM_RELIABLE_FIFO,
    .slotCount = KVMFR_CLIPBOARD_STREAM_SLOT_COUNT,
    .slotSize  = KVMFR_CLIPBOARD_STREAM_RECORD_BYTES
  };
  if (lgmpHostStreamNew(host, toClient, &this.hostToClient) != LGMP_OK ||
      lgmpHostStreamNew(host, toHost  , &this.clientToHost) != LGMP_OK)
  {
    DEBUG_ERROR("Failed to create the clipboard streams");
    clipboardHost_free();
    return false;
  }

  struct LGMPStreamDescriptor desc;
  lgmpHostStreamGetDescriptor(this.hostToClient, &desc);
  this.hostToClientDesc = toWire(&desc);
  lgmpHostStreamGetDescriptor(this.clientToHost, &desc);
  this.clientToHostDesc = toWire(&desc);

  this.endpointGeneration = ENDPOINT_GENERATION;
  this.statusDirty = true;
  return true;
}

bool clipboardHost_start(void)
{
  if (!this.queue || this.thread)
    return this.thread != NULL;

  atomic_store(&this.stop, false);
  this.statusDirty = true;
  if (!lgCreateThread("ClipboardThread", clipboardThread, NULL, &this.thread))
  {
    DEBUG_ERROR("Failed to create the clipboard thread");
    return false;
  }
  return true;
}

void clipboardHost_stop(void)
{
  if (!this.thread)
    return;

  atomic_store(&this.stop, true);
  lgJoinThread(this.thread, NULL);
  this.thread = NULL;
}

void clipboardHost_free(void)
{
  clipboardHost_stop();

  forceUnbindStreams();
  lgmpHostStreamFree(&this.clientToHost);
  lgmpHostStreamFree(&this.hostToClient);
  for (unsigned i = 0; i < MEMORY_COUNT; ++i)
  {
    lgmpHostMemFree(&this.statusMemory [i]);
    lgmpHostMemFree(&this.messageMemory[i]);
  }

  this.queue         = NULL;
  this.cachedValid   = false;
  this.hostFormats   = 0;
  this.ownerClientID = 0;
}
