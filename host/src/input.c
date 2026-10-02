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

// C port of idd/LGIdd/transport/lgmp/CLGMPInputTransport.cpp. Everything
// runs on the worker thread, so the Windows locks are not needed; the input
// target (the Windows virtual HID device) is replaced by the os_input*
// platform functions.

#include "input.h"
#include "interface/platform.h"

#include "common/debug.h"
#include "common/thread.h"
#include "common/time.h"

#include "lgmp/stream.h"
#include <LGProtocol/KVMFRInput.h>
#include <LGProtocol/LGMPConfig.h>

#include <stdatomic.h>
#include <string.h>

#define OWNER_LEASE_MS 500
#define DRAIN_LIMIT    256

#define MAX_SPLIT_REPORTS 4
#define MAX_MOUSE_DELTA   (INT16_MAX * MAX_SPLIT_REPORTS)
#define MIN_MOUSE_DELTA   (INT16_MIN * MAX_SPLIT_REPORTS)
#define MAX_MOUSE_WHEEL   (INT8_MAX  * MAX_SPLIT_REPORTS)
#define MIN_MOUSE_WHEEL   (-INT8_MAX * MAX_SPLIT_REPORTS)

static const struct LGMPQueueConfig INPUT_QUEUE_CONFIG =
{
  .queueID     = LGMP_Q_INPUT,
  .numMessages = LGMP_Q_INPUT_LEN,
  .subTimeout  = 1000
};

struct StreamEndpoint
{
  PLGMPHostStream             stream;
  struct LGMPStreamDescriptor descriptor;
  uint32_t                    clientID;
  uint32_t                    epoch;
  bool                        draining;
};

struct TargetState
{
  bool    available;
  bool    owned;
  bool    keyboardLEDsValid;
  uint8_t keyboardLEDs;
  uint32_t ownerClient;
  uint32_t ownerGeneration;
};

static struct
{
  PLGMPHostQueue        queue;
  PLGMPMemory           statusMemory[LGMP_Q_INPUT_LEN];
  struct StreamEndpoint endpoint[KVMFR_INPUT_STREAM_ENDPOINT_COUNT];

  LGThread  * thread;
  atomic_bool stop;

  uint32_t ownerClientID;
  uint32_t ownerGeneration;
  uint32_t ownerSequence;
  uint64_t ownerDeadline;   // ms

  struct TargetState targetState;
  uint32_t endpointGeneration;
  uint32_t streamGeneration;
  unsigned drainCursor;
  uint32_t statusSerial;
  bool     statusDirty;
}
this;

static inline uint32_t seqNext(uint32_t value)
{
  const uint32_t next = value + 1;
  return next ? next : 1;
}

static inline void seqInc(uint32_t * value)
{
  *value = seqNext(*value);
}

static bool isZero(const void * data, size_t size)
{
  const uint8_t * byte = data;
  for (size_t i = 0; i < size; ++i)
    if (byte[i])
      return false;
  return true;
}

static KVMFRStreamDescriptor exportStreamDescriptor(
    const struct LGMPStreamDescriptor * source)
{
  KVMFRStreamDescriptor result =
  {
    .magic      = source->magic,
    .version    = source->version,
    .size       = source->size,
    .offset     = source->offset,
    .regionSize = source->regionSize,
    .direction  = source->direction,
    .policy     = source->policy,
    .slotCount  = source->slotCount,
    .slotSize   = source->slotSize
  };
  return result;
}

// the input target: the local OS, owned by whichever client claimed it
static struct TargetState getTargetState(void)
{
  struct TargetState state = { 0 };
  state.available = os_inputAvailable();
  if (state.available && this.ownerClientID)
  {
    state.owned           = true;
    state.ownerClient     = this.ownerClientID;
    state.ownerGeneration = this.ownerGeneration;
  }
  if (state.available)
    state.keyboardLEDsValid = os_inputKeyboardLEDs(&state.keyboardLEDs);
  return state;
}

static void updateTargetState(void)
{
  const struct TargetState state = getTargetState();
  if (memcmp(&state, &this.targetState, sizeof(state)) == 0)
    return;

  if (state.available != this.targetState.available)
    seqInc(&this.endpointGeneration);

  this.targetState = state;
  this.statusDirty = true;
}

bool inputHost_setup(PLGMPHost host)
{
  LGMP_STATUS status = lgmpHostQueueNew(host, INPUT_QUEUE_CONFIG, &this.queue);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostQueueNew Failed (Input): %s",
        lgmpStatusString(status));
    return false;
  }

  const struct LGMPStreamConfig streamConfig =
  {
    .direction = LGMP_STREAM_CLIENT_TO_HOST,
    .policy    = LGMP_STREAM_RELIABLE_FIFO,
    .slotCount = KVMFR_INPUT_STREAM_SLOT_COUNT,
    .slotSize  = KVMFR_INPUT_STREAM_SLOT_SIZE
  };

  for (unsigned i = 0; i < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++i)
  {
    struct StreamEndpoint * ep = &this.endpoint[i];
    status = lgmpHostStreamNew(host, streamConfig, &ep->stream);
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostStreamNew Failed (Input): %s",
          lgmpStatusString(status));
      inputHost_free();
      return false;
    }
    lgmpHostStreamGetDescriptor(ep->stream, &ep->descriptor);
  }
  seqInc(&this.streamGeneration);

  for (unsigned i = 0; i < LGMP_Q_INPUT_LEN; ++i)
  {
    status = lgmpHostMemAlloc(host, sizeof(KVMFRInputStatus),
        &this.statusMemory[i]);
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostMemAlloc Failed (Input Status): %s",
          lgmpStatusString(status));
      inputHost_free();
      return false;
    }
    memset(lgmpHostMemPtr(this.statusMemory[i]), 0, sizeof(KVMFRInputStatus));
  }

  this.statusDirty = true;
  return true;
}

static bool reconcileStreams(bool * changed)
{
  *changed = false;
  uint32_t activeIDs[32] = { 0 };
  unsigned activeCount   = 0;
  LGMP_STATUS status = lgmpHostGetClientIDs(this.queue, activeIDs, &activeCount);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("lgmpHostGetClientIDs Failed (Input): %s",
        lgmpStatusString(status));
    return false;
  }

  // unbind endpoints whose client went away, or that are draining
  for (unsigned e = 0; e < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++e)
  {
    struct StreamEndpoint * ep = &this.endpoint[e];
    if (!ep->clientID)
      continue;

    bool active = false;
    for (unsigned i = 0; i < activeCount; ++i)
      if (activeIDs[i] == ep->clientID)
      {
        active = true;
        break;
      }

    if (active && !ep->draining)
      continue;

    if (!active && !ep->draining)
    {
      ep->draining = true;
      *changed     = true;
    }

    status = lgmpHostStreamUnbind(ep->stream);
    if (status == LGMP_ERR_STREAM_BUSY)
      continue; // an outstanding reservation, keep draining
    if (status != LGMP_OK && !(status == LGMP_ERR_STREAM_UNBOUND && !active))
    {
      DEBUG_ERROR("lgmpHostStreamUnbind Failed (Input): %s",
          lgmpStatusString(status));
      return false;
    }

    ep->clientID = 0;
    ep->epoch    = 0;
    ep->draining = false;
    *changed     = true;
  }

  // bind new clients to free endpoints
  for (unsigned i = 0; i < activeCount; ++i)
  {
    const uint32_t clientID = activeIDs[i];
    bool bound = false;
    struct StreamEndpoint * available = NULL;
    for (unsigned e = 0; e < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++e)
    {
      if (this.endpoint[e].clientID == clientID)
      {
        bound = true;
        break;
      }
      if (!available && !this.endpoint[e].clientID)
        available = &this.endpoint[e];
    }
    if (bound || !available)
      continue;

    uint32_t epoch = 0;
    status = lgmpHostStreamBind(available->stream, clientID, &epoch);
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostStreamBind Failed (Input client %u): %s",
          clientID, lgmpStatusString(status));
      return false;
    }
    available->clientID = clientID;
    available->epoch    = epoch;
    available->draining = false;
    *changed            = true;
    DEBUG_INFO("Input client %u bound", clientID);
  }

  if (*changed)
    seqInc(&this.streamGeneration);
  return true;
}

static void resetStreams(void)
{
  bool changed = false;
  for (unsigned e = 0; e < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++e)
  {
    struct StreamEndpoint * ep = &this.endpoint[e];
    if (!ep->clientID)
      continue;

    const LGMP_STATUS status = lgmpHostStreamUnbind(ep->stream);
    if (status == LGMP_OK)
    {
      ep->clientID = 0;
      ep->epoch    = 0;
      ep->draining = false;
    }
    else if (status == LGMP_ERR_STREAM_BUSY)
      ep->draining = true;
    else
      DEBUG_WARN("lgmpHostStreamUnbind Failed (Input): %s",
          lgmpStatusString(status));
    changed = true;
  }

  if (changed)
  {
    seqInc(&this.streamGeneration);
    this.statusDirty = true;
  }
}

static bool publishStatus(void)
{
  if (!this.queue)
    return true;

  bool streamChanged = false;
  if (!reconcileStreams(&streamChanged))
    return false;

  if (lgmpHostQueueNewSubs(this.queue) || streamChanged)
    this.statusDirty = true;

  if (!this.statusDirty || !lgmpHostQueueHasSubs(this.queue))
    return true;

  PLGMPMemory memory = NULL;
  for (unsigned i = 0; i < LGMP_Q_INPUT_LEN; ++i)
    if (!lgmpHostQueuePayloadPending(this.queue, this.statusMemory[i]))
    {
      memory = this.statusMemory[i];
      break;
    }
  if (!memory)
    return true;

  const struct TargetState * ts = &this.targetState;
  KVMFRInputStatus status = { 0 };
  status.version      = KVMFR_INPUT_VERSION;
  status.capabilities = ts->available ?
    KVMFR_INPUT_CAP_MOUSE_RELATIVE |
    KVMFR_INPUT_CAP_MOUSE_ABSOLUTE |
    KVMFR_INPUT_CAP_KEYBOARD : 0;
  status.flags = ts->available ? KVMFR_INPUT_STATUS_AVAILABLE : 0;
  if (ts->owned)
  {
    status.flags          |= KVMFR_INPUT_STATUS_HAS_OWNER;
    status.ownerClientID   = ts->ownerClient;
    status.ownerGeneration = ts->ownerGeneration;
  }
  if (ts->available && ts->keyboardLEDsValid)
  {
    status.flags       |= KVMFR_INPUT_STATUS_KEYBOARD_LEDS_VALID;
    status.keyboardLEDs = ts->keyboardLEDs;
  }
  status.generation          = this.endpointGeneration;
  status.lease               = OWNER_LEASE_MS;
  status.maxButtons          = KVMFR_INPUT_MOUSE_BUTTON_COUNT;
  status.streamVersion       = KVMFR_INPUT_STREAM_VERSION;
  status.streamEndpointCount = KVMFR_INPUT_STREAM_ENDPOINT_COUNT;
  status.streamGeneration    = this.streamGeneration;

  for (unsigned i = 0; i < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++i)
  {
    const struct StreamEndpoint * ep = &this.endpoint[i];
    KVMFRInputStreamEndpoint * out = &status.streamEndpoint[i];
    out->stream = exportStreamDescriptor(&ep->descriptor);
    out->flags  = KVMFR_INPUT_STREAM_ENDPOINT_AVAILABLE;
    if (ep->clientID && !ep->draining)
    {
      out->boundClientID     = ep->clientID;
      out->bindingGeneration = ep->epoch;
      out->flags            |= KVMFR_INPUT_STREAM_ENDPOINT_BOUND;
    }
  }
  memcpy(lgmpHostMemPtr(memory), &status, sizeof(status));

  const uint32_t serial = seqNext(this.statusSerial);
  const LGMP_STATUS result = lgmpHostQueuePost(this.queue, serial, memory);
  if (result == LGMP_OK)
  {
    this.statusSerial = serial;
    this.statusDirty  = false;
  }
  else if (result != LGMP_ERR_QUEUE_FULL)
  {
    DEBUG_WARN("lgmpHostQueuePost Failed (Input Status): %s",
        lgmpStatusString(result));
    return false;
  }
  return true;
}

static inline bool isOwner(uint32_t clientID, uint32_t generation)
{
  return this.ownerClientID == clientID &&
    this.ownerGeneration == generation;
}

static void renewLease(void)
{
  this.ownerDeadline = microtime() / 1000 + OWNER_LEASE_MS;
}

static void releaseOwner(bool reset, const char * reason)
{
  if (!this.ownerClientID)
    return;

  DEBUG_INFO("Input released by client %u: %s", this.ownerClientID, reason);

  // a release always lets go of held keys and buttons so nothing sticks
  (void)reset;
  os_inputReset();

  this.ownerClientID   = 0;
  this.ownerGeneration = 0;
  this.ownerSequence   = 0;
  this.ownerDeadline   = 0;
  updateTargetState();
}

static bool claim(uint32_t clientID, const KVMFRInputMessage * msg)
{
  if (msg->sequence != 1 || !os_inputAvailable())
  {
    updateTargetState();
    return false;
  }

  this.ownerClientID   = clientID;
  this.ownerGeneration = msg->generation;
  this.ownerSequence   = msg->sequence;
  renewLease();
  updateTargetState();
  DEBUG_INFO("Input claimed by client %u", clientID);
  return true;
}

static void checkOwner(void)
{
  if (this.ownerClientID)
  {
    bool found = false, retiring = false;
    for (unsigned e = 0; e < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++e)
      if (this.endpoint[e].clientID == this.ownerClientID)
      {
        found    = true;
        retiring = this.endpoint[e].draining;
        break;
      }

    if (!found || retiring)
    {
      releaseOwner(true, "client disconnected");
      return;
    }
  }

  updateTargetState();

  if (!this.ownerClientID)
    return;

  if (!this.targetState.available)
  {
    releaseOwner(false, "input unavailable");
    return;
  }

  if (microtime() / 1000 >= this.ownerDeadline)
    releaseOwner(true, "lease expired");
}

static bool validatePayload(const KVMFRInputMessage * msg)
{
  switch (msg->type)
  {
    case KVMFR_INPUT_MESSAGE_CLAIM:
    case KVMFR_INPUT_MESSAGE_RELEASE:
    case KVMFR_INPUT_MESSAGE_KEEPALIVE:
    case KVMFR_INPUT_MESSAGE_RESET:
      return isZero(&msg->payload, sizeof(msg->payload));

    case KVMFR_INPUT_MESSAGE_MOUSE_RELATIVE:
    {
      const KVMFRInputMouseRelative * m = &msg->payload.mouseRelative;
      return m->deltaX >= MIN_MOUSE_DELTA && m->deltaX <= MAX_MOUSE_DELTA &&
             m->deltaY >= MIN_MOUSE_DELTA && m->deltaY <= MAX_MOUSE_DELTA &&
             m->wheel  >= MIN_MOUSE_WHEEL && m->wheel  <= MAX_MOUSE_WHEEL;
    }

    case KVMFR_INPUT_MESSAGE_MOUSE_ABSOLUTE:
    {
      const KVMFRInputMouseAbsolute * m = &msg->payload.mouseAbsolute;
      return m->x <= KVMFR_INPUT_MOUSE_ABSOLUTE_MAX &&
             m->y <= KVMFR_INPUT_MOUSE_ABSOLUTE_MAX &&
             m->wheel >= MIN_MOUSE_WHEEL && m->wheel <= MAX_MOUSE_WHEEL &&
             !m->reserved;
    }

    case KVMFR_INPUT_MESSAGE_KEYBOARD:
    {
      const KVMFRInputKeyboard * k = &msg->payload.keyboard;
      if (!isZero(k->reserved, sizeof(k->reserved)))
        return false;
      for (unsigned i = 0; i < KVMFR_INPUT_KEYBOARD_KEY_COUNT; ++i)
        if (k->keys[i] > KVMFR_INPUT_KEYBOARD_USAGE_MAX)
          return false;
      return true;
    }

    default:
      return false;
  }
}

static bool processMessage(uint32_t clientID, const KVMFRInputMessage * msg)
{
  const bool owner = isOwner(clientID, msg->generation);

  if (!msg->generation || !msg->sequence || msg->reserved ||
      !validatePayload(msg))
  {
    if (owner)
      releaseOwner(true, "malformed message");
    return false;
  }

  if (msg->type == KVMFR_INPUT_MESSAGE_CLAIM)
  {
    if (this.ownerClientID)
    {
      if (!owner)
        return true; // someone else owns the input
      if (msg->sequence == 1 && this.ownerSequence == 1)
        return true; // duplicate claim
      releaseOwner(true, "unexpected claim");
      return false;
    }
    return claim(clientID, msg);
  }

  if (!owner)
    return true;

  if (msg->sequence != seqNext(this.ownerSequence))
  {
    releaseOwner(true, "sequence error");
    return false;
  }

  bool ok = true;
  switch (msg->type)
  {
    case KVMFR_INPUT_MESSAGE_RELEASE:
      releaseOwner(true, "client released");
      return true;

    case KVMFR_INPUT_MESSAGE_KEEPALIVE:
      ok = os_inputAvailable();
      break;

    case KVMFR_INPUT_MESSAGE_RESET:
      os_inputReset();
      break;

    case KVMFR_INPUT_MESSAGE_MOUSE_RELATIVE:
    {
      const KVMFRInputMouseRelative * m = &msg->payload.mouseRelative;
      ok = os_inputMouseRelative(m->deltaX, m->deltaY, m->wheel, m->buttons);
      break;
    }

    case KVMFR_INPUT_MESSAGE_MOUSE_ABSOLUTE:
    {
      const KVMFRInputMouseAbsolute * m = &msg->payload.mouseAbsolute;
      ok = os_inputMouseAbsolute(m->x, m->y, m->wheel, m->buttons);
      break;
    }

    case KVMFR_INPUT_MESSAGE_KEYBOARD:
      ok = os_inputKeyboard(msg->payload.keyboard.modifiers,
          msg->payload.keyboard.keys);
      break;
  }

  if (!ok)
  {
    releaseOwner(true, "delivery failed");
    return false;
  }

  updateTargetState();
  this.ownerSequence = msg->sequence;
  renewLease();
  return true;
}

static bool drainStreamMessages(bool * received)
{
  *received = false;
  for (unsigned count = 0; count < DRAIN_LIMIT; ++count)
  {
    struct StreamEndpoint * selected = NULL;
    LGMPStreamBuffer buffer = { 0 };

    for (unsigned scanned = 0; scanned < KVMFR_INPUT_STREAM_ENDPOINT_COUNT;
        ++scanned)
    {
      const unsigned index = (this.drainCursor + scanned) %
        KVMFR_INPUT_STREAM_ENDPOINT_COUNT;
      struct StreamEndpoint * ep = &this.endpoint[index];
      if (!ep->clientID)
        continue;

      const LGMP_STATUS status = lgmpHostStreamReadPeek(ep->stream, &buffer);
      if (status == LGMP_ERR_STREAM_EMPTY || status == LGMP_ERR_STREAM_UNBOUND)
        continue;
      if (status != LGMP_OK)
      {
        DEBUG_ERROR("lgmpHostStreamReadPeek Failed (Input): %s",
            lgmpStatusString(status));
        return false;
      }

      selected = ep;
      this.drainCursor = (index + 1) % KVMFR_INPUT_STREAM_ENDPOINT_COUNT;
      break;
    }

    if (!selected)
      break;

    *received = true;

    // retired endpoints are drained only to finish their unbind
    if (!selected->draining)
    {
      if (buffer.size != sizeof(KVMFRInputMessage))
      {
        DEBUG_WARN("Ignoring invalid KVMFR input stream message size");
        if (selected->clientID == this.ownerClientID)
          releaseOwner(true, "bad message size");
      }
      else
      {
        KVMFRInputMessage msg;
        memcpy(&msg, buffer.data, sizeof(msg));
        processMessage(selected->clientID, &msg);
      }
    }

    const LGMP_STATUS status = lgmpHostStreamReadRelease(selected->stream,
        &buffer);
    if (status != LGMP_OK)
    {
      DEBUG_ERROR("lgmpHostStreamReadRelease Failed (Input): %s",
          lgmpStatusString(status));
      return false;
    }
  }

  return true;
}

static int inputThread(void * opaque)
{
  LGMPStreamPollState poll;
  const struct LGMPStreamPollConfig pollConfig =
  {
    .spinCount = 64,
    .minWaitUs = 25,
    .maxWaitUs = 1000
  };

  LGMP_STATUS status = lgmpStreamPollInit(&poll, pollConfig);
  if (status != LGMP_OK)
  {
    DEBUG_ERROR("Failed to initialize LGMP input polling: %s",
        lgmpStatusString(status));
    return 1;
  }

  if (!os_inputAvailable())
    DEBUG_WARN("Input injection is not available yet (Accessibility "
        "permission), the client will fall back to SPICE input");

  while (!atomic_load(&this.stop))
  {
    checkOwner();

    bool received = false;
    if (!drainStreamMessages(&received))
      break;

    if (!publishStatus())
      break;

    if (received)
      lgmpStreamPollActivity(&poll);

    const uint32_t waitUs = lgmpStreamPollIdle(&poll);
    if (waitUs)
      nsleep((uint64_t)waitUs * 1000);
  }

  releaseOwner(true, "input stopped");
  this.targetState = (struct TargetState){ 0 };
  this.statusDirty = true;
  publishStatus();
  return 0;
}

bool inputHost_start(void)
{
  if (!this.queue || this.thread)
    return this.thread != NULL;

  atomic_store(&this.stop, false);
  this.targetState = getTargetState();
  seqInc(&this.endpointGeneration);
  this.statusDirty = true;

  if (!lgCreateThread("InputThread", inputThread, NULL, &this.thread))
  {
    DEBUG_ERROR("Failed to create the input thread");
    return false;
  }
  return true;
}

void inputHost_stop(void)
{
  if (!this.thread)
    return;

  atomic_store(&this.stop, true);
  lgJoinThread(this.thread, NULL);
  this.thread = NULL;

  this.ownerClientID   = 0;
  this.ownerGeneration = 0;
  this.ownerSequence   = 0;
  this.ownerDeadline   = 0;
  resetStreams();
}

void inputHost_free(void)
{
  inputHost_stop();

  for (unsigned i = 0; i < LGMP_Q_INPUT_LEN; ++i)
    lgmpHostMemFree(&this.statusMemory[i]);

  for (unsigned i = 0; i < KVMFR_INPUT_STREAM_ENDPOINT_COUNT; ++i)
  {
    lgmpHostStreamFree(&this.endpoint[i].stream);
    memset(&this.endpoint[i], 0, sizeof(this.endpoint[i]));
  }

  this.streamGeneration = 0;
  this.drainCursor      = 0;
  this.queue            = NULL;
}
