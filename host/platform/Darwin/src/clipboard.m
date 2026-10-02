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

// macOS side of the KVMFR clipboard (the "Helper" on Windows).
//
// macOS -> client: the general pasteboard is polled; a change is offered to
// the client (text, PNG image, files) and served when the client requests it.
// Copied files are listed and read from disk on demand.
//
// client -> macOS: an offer from the client is fetched right away (text, an
// image, files into a cache folder) and then written to the pasteboard. A
// background process cannot serve lazy pasteboard promises, so fetching at
// paste time is not an option.
//
// Everything runs on the clipboard worker thread.

#import <AppKit/AppKit.h>

#include "interface/platform.h"
#include "clipboard.h"
#include "common/debug.h"
#include "common/time.h"

#include <fcntl.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>

#define POLL_INTERVAL_US   250000
#define MAX_ITEM_BYTES     (512u << 20)
#define OUTBOX_LEN         128
#define MAX_OUT_JOBS       (KVMFR_CLIPBOARD_FILE_MAX_REQUESTS + 4)
#define MAX_ACQUISITIONS   KVMFR_CLIPBOARD_FILE_MAX_ACQUISITIONS

// --- shared ----------------------------------------------------------------

static KVMFRClipboardMessage l_outbox[OUTBOX_LEN];
static unsigned              l_outboxCount;
static uint64_t              l_nextGeneration;
static uint64_t              l_nextTransfer;

static uint64_t newGeneration(void)
{
  return ++l_nextGeneration;
}

static uint64_t newTransfer(void)
{
  return KVMFR_CLIPBOARD_TRANSFER_HELPER | (++l_nextTransfer);
}

static void sendControl(const KVMFRClipboardMessage * message)
{
  if (l_outboxCount == OUTBOX_LEN)
  {
    DEBUG_WARN("Clipboard outbox full, dropping a message");
    return;
  }
  l_outbox[l_outboxCount] = *message;
  l_outbox[l_outboxCount].version = KVMFR_CLIPBOARD_VERSION;
  ++l_outboxCount;
}

static void pumpOutbox(void)
{
  while (l_outboxCount)
  {
    if (clipboardHost_sendControl(&l_outbox[0]) == CLIPBOARD_BUSY)
      return;
    memmove(&l_outbox[0], &l_outbox[1],
        sizeof(l_outbox[0]) * (l_outboxCount - 1));
    --l_outboxCount;
  }
}

static NSString * cacheRoot(void)
{
  NSString * caches = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  return [caches stringByAppendingPathComponent:
    @"local.lgmac.LookingGlassHost/Clipboard"];
}

// --- macOS -> client: the local clipboard ----------------------------------

// stored in raw memory, references are managed with CFBridgingRetain/Release
typedef struct LocalNode
{
  __unsafe_unretained NSString       * path;
  uint32_t                             type;     // KVMFR_CLIPBOARD_FILE_TYPE_*
  __unsafe_unretained NSMutableArray * children; // child node ids, NSNumber
}
LocalNode;

static struct
{
  NSInteger   seenChange;
  uint64_t    lastPoll;

  uint64_t    generation;     // dataset offered to the client
  uint32_t    formats;
  NSData    * text;           // UTF-8, no terminator
  NSData    * png;
  NSArray   * paths;          // top level file paths
  NSMutableData * nodes;      // LocalNode[], node id = index + 1

  // client acquisitions of our file dataset
  uint64_t    acquisition[MAX_ACQUISITIONS];
}
L;

static void freeNodes(void)
{
  if (!L.nodes)
    return;
  LocalNode * n = L.nodes.mutableBytes;
  const size_t count = L.nodes.length / sizeof(LocalNode);
  for (size_t i = 0; i < count; ++i)
  {
    // balance the CFBridgingRetain in addNode
    if (n[i].path)     CFBridgingRelease((__bridge CFTypeRef)n[i].path);
    if (n[i].children) CFBridgingRelease((__bridge CFTypeRef)n[i].children);
  }
  L.nodes = nil;
}

static uint64_t addNode(NSString * path, uint32_t type)
{
  LocalNode node =
  {
    .path     = (__bridge NSString *)CFBridgingRetain(path),
    .type     = type,
    .children = nil
  };
  [L.nodes appendBytes:&node length:sizeof(node)];
  return L.nodes.length / sizeof(LocalNode);
}

static LocalNode * getNode(uint64_t id)
{
  if (!id || id > L.nodes.length / sizeof(LocalNode))
    return NULL;
  return &((LocalNode *)L.nodes.mutableBytes)[id - 1];
}

static bool fileType(NSString * path, uint32_t * type, struct stat * st)
{
  if (lstat(path.fileSystemRepresentation, st) != 0)
    return false;
  if (S_ISREG(st->st_mode))
    *type = KVMFR_CLIPBOARD_FILE_TYPE_REGULAR;
  else if (S_ISDIR(st->st_mode))
    *type = KVMFR_CLIPBOARD_FILE_TYPE_DIRECTORY;
  else
    return false; // symlinks, devices, sockets are not shared
  return true;
}

static void snapshotPasteboard(NSPasteboard * pb)
{
  L.text  = nil;
  L.png   = nil;
  L.paths = nil;
  freeNodes();
  for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
    L.acquisition[i] = 0;

  uint32_t formats = 0;

  // password managers mark secrets as concealed, never share those
  if (![pb.types containsObject:@"org.nspasteboard.ConcealedType"])
  {
    NSArray * urls = [pb readObjectsForClasses:@[NSURL.class]
      options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (urls.count)
    {
      NSMutableArray * paths = [NSMutableArray array];
      L.nodes = [NSMutableData data];
      for (NSURL * url in urls)
      {
        uint32_t type;
        struct stat st;
        if (url.path && fileType(url.path, &type, &st))
        {
          [paths addObject:url.path];
          addNode(url.path, type);
        }
      }
      if (paths.count)
      {
        L.paths = paths;
        formats |= KVMFR_CLIPBOARD_FORMAT_MASK_FILES;
      }
    }

    NSString * string = [pb stringForType:NSPasteboardTypeString];
    if (string.length)
    {
      L.text = [string dataUsingEncoding:NSUTF8StringEncoding];
      formats |= KVMFR_CLIPBOARD_FORMAT_MASK_TEXT;
    }

    // Finder puts file icons on the pasteboard too, only images that are
    // not a file copy are shared
    if (!L.paths)
    {
      NSData * png = [pb dataForType:NSPasteboardTypePNG];
      if (!png)
      {
        NSData * tiff = [pb dataForType:NSPasteboardTypeTIFF];
        if (tiff)
        {
          NSBitmapImageRep * rep = [NSBitmapImageRep imageRepWithData:tiff];
          png = [rep representationUsingType:NSBitmapImageFileTypePNG
            properties:@{}];
        }
      }
      if (png.length)
      {
        L.png = png;
        formats |= KVMFR_CLIPBOARD_FORMAT_MASK_PNG;
      }
    }
  }

  L.generation = newGeneration();
  L.formats    = formats;

  KVMFRClipboardMessage m = { 0 };
  m.type                = formats ? KVMFR_CLIPBOARD_MESSAGE_OFFER :
                                    KVMFR_CLIPBOARD_MESSAGE_CLEAR;
  m.clipboardGeneration = L.generation;
  m.token               = formats;
  // OFFER/CLEAR are cached by the transport, send directly so the newest
  // replaces the cached one even without an owner
  clipboardHost_sendControl(&m);
}

static void pollPasteboard(void)
{
  const uint64_t now = microtime();
  if (now - L.lastPoll < POLL_INTERVAL_US)
    return;
  L.lastPoll = now;

  NSPasteboard * pb = [NSPasteboard generalPasteboard];
  const NSInteger change = pb.changeCount;
  if (change == L.seenChange)
    return;
  L.seenChange = change;
  snapshotPasteboard(pb);
}

// --- outbound transfers (DATA / FILE_DATA to the client) --------------------

typedef struct OutJob
{
  bool     file;
  uint64_t transfer;
  uint64_t dataset;
  uint32_t format;
  uint32_t operation;   // file jobs
  void   * data;        // NSData, retained
  uint64_t pos;
  uint32_t sequence;
}
OutJob;

static OutJob   l_out[MAX_OUT_JOBS];
static unsigned l_outCount;

static void dropOutJob(unsigned index)
{
  if (l_out[index].data)
    CFBridgingRelease(l_out[index].data);
  memmove(&l_out[index], &l_out[index + 1],
      sizeof(l_out[0]) * (l_outCount - index - 1));
  --l_outCount;
}

static void dropOutTransfer(uint64_t transfer)
{
  for (unsigned i = 0; i < l_outCount; ++i)
    if (l_out[i].transfer == transfer)
    {
      dropOutJob(i);
      return;
    }
}

static void dropOutDataset(uint64_t dataset)
{
  for (unsigned i = 0; i < l_outCount;)
    if (l_out[i].file && l_out[i].dataset == dataset)
      dropOutJob(i);
    else
      ++i;
}

static bool queueOutJob(bool file, const KVMFRClipboardMessage * request,
    uint32_t format, NSData * data)
{
  if (l_outCount == MAX_OUT_JOBS)
    return false;

  OutJob * job = &l_out[l_outCount++];
  memset(job, 0, sizeof(*job));
  job->file      = file;
  job->transfer  = request->transfer;
  job->dataset   = request->clipboardGeneration;
  job->format    = format;
  job->operation = file ? request->token : 0;
  job->data      = (void *)CFBridgingRetain(data ?: [NSData data]);
  return true;
}

static void pumpOutJobs(void)
{
  while (l_outCount)
  {
    OutJob * job  = &l_out[0];
    NSData * data = (__bridge NSData *)job->data;
    const uint64_t total = data.length;
    const uint64_t left  = total - job->pos;
    const uint32_t chunk = left > KVMFR_CLIPBOARD_DATA_BYTES ?
      KVMFR_CLIPBOARD_DATA_BYTES : (uint32_t)left;
    const bool begin = job->pos == 0;
    const bool end   = job->pos + chunk == total;

    KVMFRClipboardMessage r = { 0 };
    r.type                = job->file ? KVMFR_CLIPBOARD_MESSAGE_FILE_DATA :
                                        KVMFR_CLIPBOARD_MESSAGE_DATA;
    r.clipboardGeneration = job->dataset;
    r.transfer            = job->transfer;
    r.offset              = job->pos;
    r.format              = job->format;
    r.token               = job->operation;
    r.sequence            = job->sequence;
    r.length              = chunk;
    r.flags               = (begin ? KVMFR_CLIPBOARD_FLAG_BEGIN : 0) |
                            (end   ? KVMFR_CLIPBOARD_FLAG_END   : 0);
    r.size                = end ? job->pos + chunk :
                            begin ? total : KVMFR_CLIPBOARD_SIZE_UNKNOWN;

    const ClipboardSendResult result = clipboardHost_sendStream(&r,
        (const uint8_t *)data.bytes + job->pos);
    if (result == CLIPBOARD_BUSY)
      return;
    if (result == CLIPBOARD_NO_OWNER)
    {
      dropOutJob(0);
      continue;
    }

    job->pos += chunk;
    ++job->sequence;
    if (end)
      dropOutJob(0);
  }
}

// --- serving our files to the client -----------------------------------------

static bool hasAcquisition(uint64_t transfer)
{
  for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
    if (L.acquisition[i] && L.acquisition[i] == transfer)
      return true;
  return false;
}

static bool datasetAcquired(void)
{
  for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
    if (L.acquisition[i])
      return true;
  return false;
}

static void fileReply(const KVMFRClipboardMessage * request, uint32_t type,
    uint32_t error)
{
  KVMFRClipboardMessage m = { 0 };
  m.type                = type;
  m.clipboardGeneration = request->clipboardGeneration;
  m.transfer            = request->transfer;
  m.format              = KVMFR_CLIPBOARD_FORMAT_FILES;
  m.token               = error;
  sendControl(&m);
}

static void appendEntry(NSMutableData * out, uint64_t id, LocalNode * node)
{
  struct stat st;
  uint32_t type;
  if (!fileType(node->path, &type, &st))
    return;

  NSString * name = node->path.lastPathComponent
    .precomposedStringWithCanonicalMapping;
  NSData * utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
  if (!utf8.length || utf8.length > NAME_MAX ||
      memchr(utf8.bytes, 0, utf8.length))
    return;

  KVMFRClipboardFileEntry entry =
  {
    .node       = id,
    .size       = type == KVMFR_CLIPBOARD_FILE_TYPE_REGULAR ?
                    (uint64_t)st.st_size : 0,
    .createdNs  = (uint64_t)st.st_birthtimespec.tv_sec * 1000000000ULL +
                    st.st_birthtimespec.tv_nsec,
    .modifiedNs = (uint64_t)st.st_mtimespec.tv_sec * 1000000000ULL +
                    st.st_mtimespec.tv_nsec,
    .type       = type,
    .nameLength = (uint32_t)utf8.length
  };

  const size_t bytes = KVMFR_CLIPBOARD_FILE_ENTRY_BYTES(utf8.length);
  const size_t at    = out.length;
  [out increaseLengthBy:bytes];   // zero filled, so the padding is too
  memcpy((uint8_t *)out.mutableBytes + at, &entry, sizeof(entry));
  memcpy((uint8_t *)out.mutableBytes + at + sizeof(entry), utf8.bytes,
      utf8.length);
}

static NSData * listNode(uint64_t id, uint32_t * error)
{
  NSMutableData * out = [NSMutableData data];

  if (id == KVMFR_CLIPBOARD_FILE_ROOT_NODE)
  {
    for (uint64_t i = 1; i <= L.paths.count; ++i)
      appendEntry(out, i, getNode(i));
    return out;
  }

  LocalNode * node = getNode(id);
  if (!node)
  {
    *error = KVMFR_CLIPBOARD_FILE_ERROR_NOT_FOUND;
    return nil;
  }
  if (node->type != KVMFR_CLIPBOARD_FILE_TYPE_DIRECTORY)
  {
    *error = KVMFR_CLIPBOARD_FILE_ERROR_NOT_DIRECTORY;
    return nil;
  }

  // assign node ids once so repeated listings stay stable
  if (!node->children)
  {
    NSString * dir = node->path;
    NSError  * err = nil;
    NSArray  * names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:dir error:&err];
    if (!names)
    {
      *error = KVMFR_CLIPBOARD_FILE_ERROR_ACCESS;
      return nil;
    }

    NSMutableArray * children = [NSMutableArray array];
    for (NSString * name in names)
    {
      NSString * path = [dir stringByAppendingPathComponent:name];
      uint32_t type;
      struct stat st;
      if (fileType(path, &type, &st))
        [children addObject:@(addNode(path, type))];
    }
    // addNode may have moved the node array
    node = getNode(id);
    node->children = (__bridge NSMutableArray *)CFBridgingRetain(children);
  }

  for (NSNumber * child in node->children)
    appendEntry(out, child.unsignedLongLongValue,
        getNode(child.unsignedLongLongValue));
  return out;
}

static NSData * readNode(uint64_t id, uint64_t offset, uint32_t bytes,
    uint32_t * error)
{
  LocalNode * node = getNode(id);
  if (!node)
  {
    *error = KVMFR_CLIPBOARD_FILE_ERROR_NOT_FOUND;
    return nil;
  }
  if (node->type != KVMFR_CLIPBOARD_FILE_TYPE_REGULAR)
  {
    *error = KVMFR_CLIPBOARD_FILE_ERROR_IS_DIRECTORY;
    return nil;
  }

  const int fd = open(node->path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0)
  {
    *error = KVMFR_CLIPBOARD_FILE_ERROR_ACCESS;
    return nil;
  }

  NSMutableData * data = [NSMutableData dataWithLength:bytes];
  size_t got = 0;
  while (got < bytes)
  {
    const ssize_t r = pread(fd, (uint8_t *)data.mutableBytes + got,
        bytes - got, (off_t)(offset + got));
    if (r < 0)
    {
      close(fd);
      *error = KVMFR_CLIPBOARD_FILE_ERROR_IO;
      return nil;
    }
    if (r == 0)
      break; // end of file
    got += (size_t)r;
  }
  close(fd);
  data.length = got;
  return data;
}

static void serveFileRequest(const KVMFRClipboardMessage * m)
{
  if (m->clipboardGeneration != L.generation || !datasetAcquired())
  {
    fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL,
        KVMFR_CLIPBOARD_FILE_ERROR_STALE);
    return;
  }

  uint32_t error = KVMFR_CLIPBOARD_FILE_ERROR_NONE;
  NSData * data;
  if (m->token == KVMFR_CLIPBOARD_FILE_OP_LIST)
    data = listNode(m->size, &error);
  else
    data = readNode(m->size, m->offset, m->flags, &error);

  if (!data)
  {
    fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL, error);
    return;
  }

  if (!queueOutJob(true, m, KVMFR_CLIPBOARD_FORMAT_FILES, data))
    fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL,
        KVMFR_CLIPBOARD_FILE_ERROR_NO_MEMORY);
}

static void clientAcquire(const KVMFRClipboardMessage * m)
{
  if (m->clipboardGeneration != L.generation ||
      !(L.formats & KVMFR_CLIPBOARD_FORMAT_MASK_FILES))
  {
    fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRED,
        KVMFR_CLIPBOARD_FILE_ERROR_STALE);
    return;
  }

  for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
    if (!L.acquisition[i])
    {
      L.acquisition[i] = m->transfer;
      fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRED,
          KVMFR_CLIPBOARD_FILE_ERROR_NONE);
      return;
    }

  fileReply(m, KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRED,
      KVMFR_CLIPBOARD_FILE_ERROR_NO_MEMORY);
}

static void clientReleaseAcquisition(uint64_t transfer)
{
  for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
    if (L.acquisition[i] == transfer)
      L.acquisition[i] = 0;
  if (!datasetAcquired())
    dropOutDataset(L.generation);
}

// --- client -> macOS: fetching the client's clipboard ------------------------

typedef enum
{
  FETCH_IDLE,
  FETCH_DATA,
  FETCH_ACQUIRE,
  FETCH_FILES
}
FetchState;

// heap allocated, path is managed with CFBridgingRetain/Release
typedef struct FileOp
{
  uint32_t   operation;
  uint64_t   node;
  __unsafe_unretained NSString * path; // directory to fill, or file to write
  uint64_t   size;
  uint64_t   offset;
}
FileOp;

static struct
{
  uint64_t   generation;
  uint32_t   formats;

  // remaining steps for the current offer
  bool       wantText;
  uint32_t   wantImage;   // KVMFR format, 0 = none
  bool       wantFiles;

  FetchState state;

  // the active request (DATA or FILE_DATA)
  uint64_t        transfer;
  uint32_t        format;
  NSMutableData * buffer;
  uint64_t        nextOffset;
  uint32_t        nextSequence;
  bool            began;

  // files
  uint64_t        acquireTransfer;
  NSString      * dir;
  NSMutableArray * ops;   // NSValue(FileOp *) queue, FileOp heap allocated
  FileOp        * op;     // current
  int             fd;
  NSMutableArray * topLevel;

  // results
  NSString * text;
  NSData   * image;
  uint32_t   imageFormat;
}
R = { .fd = -1 };

static void freeOp(FileOp * op)
{
  if (!op)
    return;
  if (op->path)
    CFBridgingRelease((__bridge CFTypeRef)op->path);
  free(op);
}

static void queueOp(uint32_t operation, uint64_t node, NSString * path,
    uint64_t size, uint64_t offset)
{
  FileOp * op = calloc(1, sizeof(*op));
  op->operation = operation;
  op->node      = node;
  op->path      = (__bridge NSString *)CFBridgingRetain(path);
  op->size      = size;
  op->offset    = offset;
  [R.ops addObject:[NSValue valueWithPointer:op]];
}

static void clearFiles(void)
{
  if (R.fd >= 0)
    close(R.fd);
  R.fd = -1;
  freeOp(R.op);
  R.op = NULL;
  for (NSValue * v in R.ops)
    freeOp(v.pointerValue);
  R.ops = nil;
  R.topLevel = nil;
  R.acquireTransfer = 0;
}

// abandon everything in flight for the current client offer
static void abortFetch(bool notify)
{
  if (notify)
  {
    if (R.state == FETCH_DATA && R.transfer)
    {
      KVMFRClipboardMessage m = { 0 };
      m.type                = KVMFR_CLIPBOARD_MESSAGE_CANCEL;
      m.clipboardGeneration = R.generation;
      m.transfer            = R.transfer;
      m.format              = R.format;
      sendControl(&m);
    }

    if ((R.state == FETCH_FILES || R.state == FETCH_ACQUIRE) &&
        R.acquireTransfer)
    {
      KVMFRClipboardMessage m = { 0 };
      m.clipboardGeneration = R.generation;
      m.format              = KVMFR_CLIPBOARD_FORMAT_FILES;
      if (R.state == FETCH_FILES && R.transfer)
      {
        m.type     = KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL;
        m.transfer = R.transfer;
        m.token    = KVMFR_CLIPBOARD_FILE_ERROR_CANCELLED;
        sendControl(&m);
      }
      m.transfer = R.acquireTransfer;
      if (R.state == FETCH_FILES)
      {
        m.type  = KVMFR_CLIPBOARD_MESSAGE_FILE_RELEASE;
        m.token = 0;
      }
      else
      {
        m.type  = KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL;
        m.token = KVMFR_CLIPBOARD_FILE_ERROR_CANCELLED;
      }
      sendControl(&m);
    }
  }

  clearFiles();
  R.state     = FETCH_IDLE;
  R.transfer  = 0;
  R.buffer    = nil;
  R.wantText  = false;
  R.wantImage = 0;
  R.wantFiles = false;
  R.text      = nil;
  R.image     = nil;
}

static void writePasteboard(void)
{
  NSPasteboard * pb = [NSPasteboard generalPasteboard];

  NSMutableArray * urls = [NSMutableArray array];
  for (NSString * path in R.topLevel)
    [urls addObject:[NSURL fileURLWithPath:path]];

  if (!urls.count && !R.text && !R.image)
    return;

  [pb clearContents];
  if (urls.count)
    [pb writeObjects:urls];
  else
  {
    NSPasteboardItem * item = [[NSPasteboardItem alloc] init];
    if (R.text)
      [item setString:R.text forType:NSPasteboardTypeString];
    if (R.image)
    {
      NSBitmapImageRep * rep = [NSBitmapImageRep imageRepWithData:R.image];
      NSData * png = R.imageFormat == KVMFR_CLIPBOARD_FORMAT_PNG ? R.image :
        [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if (png)
        [item setData:png forType:NSPasteboardTypePNG];
      if (rep.TIFFRepresentation)
        [item setData:rep.TIFFRepresentation forType:NSPasteboardTypeTIFF];
    }
    [pb writeObjects:@[item]];
  }

  // our own write must not be offered back to the client
  L.seenChange = pb.changeCount;
  DEBUG_INFO("Clipboard from client: %s%s%s",
      urls.count ? "files " : "", R.text ? "text " : "",
      R.image ? "image" : "");
}

static void requestData(uint32_t format)
{
  R.state        = FETCH_DATA;
  R.transfer     = newTransfer();
  R.format       = format;
  R.buffer       = [NSMutableData data];
  R.nextOffset   = 0;
  R.nextSequence = 0;
  R.began        = false;

  KVMFRClipboardMessage m = { 0 };
  m.type                = KVMFR_CLIPBOARD_MESSAGE_REQUEST;
  m.clipboardGeneration = R.generation;
  m.transfer            = R.transfer;
  m.format              = format;
  sendControl(&m);
}

static void startFiles(void)
{
  NSString * root = cacheRoot();
  NSFileManager * fm = [NSFileManager defaultManager];

  // only the newest copied files are kept
  for (NSString * old in [fm contentsOfDirectoryAtPath:root error:nil])
    [fm removeItemAtPath:[root stringByAppendingPathComponent:old] error:nil];

  R.dir = [root stringByAppendingPathComponent:
    [NSString stringWithFormat:@"%llu", (unsigned long long)R.generation]];
  if (![fm createDirectoryAtPath:R.dir withIntermediateDirectories:YES
      attributes:nil error:nil])
  {
    DEBUG_ERROR("Failed to create %s", R.dir.UTF8String);
    R.wantFiles = false;
    return;
  }

  R.ops      = [NSMutableArray array];
  R.topLevel = [NSMutableArray array];
  R.acquireTransfer = newTransfer();
  R.state = FETCH_ACQUIRE;

  KVMFRClipboardMessage m = { 0 };
  m.type                = KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRE;
  m.clipboardGeneration = R.generation;
  m.transfer            = R.acquireTransfer;
  m.format              = KVMFR_CLIPBOARD_FORMAT_FILES;
  sendControl(&m);
}

// runs the next step of the current client offer
static void nextStep(void)
{
  if (R.state != FETCH_IDLE)
    return;

  if (R.wantFiles)
  {
    R.wantFiles = false;
    startFiles();
    if (R.state != FETCH_IDLE)
      return;
  }
  if (R.wantText)
  {
    R.wantText = false;
    requestData(KVMFR_CLIPBOARD_FORMAT_TEXT);
    return;
  }
  if (R.wantImage)
  {
    const uint32_t format = R.wantImage;
    R.wantImage = 0;
    requestData(format);
    return;
  }

  writePasteboard();
  R.text  = nil;
  R.image = nil;
  R.topLevel = nil;
}

static void clientOffer(const KVMFRClipboardMessage * m)
{
  abortFetch(true);
  R.generation = m->clipboardGeneration;
  R.formats    = m->token;

  if (R.formats & KVMFR_CLIPBOARD_FORMAT_MASK_FILES)
    R.wantFiles = true;
  else
  {
    R.wantText = (R.formats & KVMFR_CLIPBOARD_FORMAT_MASK_TEXT) != 0;
    static const uint32_t images[] =
    {
      KVMFR_CLIPBOARD_FORMAT_PNG,
      KVMFR_CLIPBOARD_FORMAT_TIFF,
      KVMFR_CLIPBOARD_FORMAT_JPEG,
      KVMFR_CLIPBOARD_FORMAT_BMP
    };
    for (unsigned i = 0; i < sizeof(images) / sizeof(images[0]); ++i)
      if (R.formats & kvmfrClipboardFormatFlag(images[i]))
      {
        R.wantImage = images[i];
        break;
      }
  }
  nextStep();
}

static void finishData(void)
{
  if (R.format == KVMFR_CLIPBOARD_FORMAT_TEXT)
  {
    NSUInteger len = R.buffer.length;
    const char * bytes = R.buffer.bytes;
    while (len && bytes[len - 1] == 0)
      --len;
    R.text = [[NSString alloc] initWithBytes:bytes length:len
      encoding:NSUTF8StringEncoding];
  }
  else
  {
    R.image       = R.buffer;
    R.imageFormat = R.format;
  }

  R.state    = FETCH_IDLE;
  R.transfer = 0;
  R.buffer   = nil;
  nextStep();
}

// accepts the next chunk of the active request, false if it is invalid
static bool acceptChunk(const KVMFRClipboardMessage * r, uint64_t limit)
{
  if (r->transfer != R.transfer || r->clipboardGeneration != R.generation ||
      r->offset != R.nextOffset || r->sequence != R.nextSequence)
    return false;
  if (!R.began && !(r->flags & KVMFR_CLIPBOARD_FLAG_BEGIN))
    return false;
  if (R.began && (r->flags & KVMFR_CLIPBOARD_FLAG_BEGIN))
    return false;
  if (r->offset + r->length > limit)
    return false;

  R.began = true;
  R.nextOffset += r->length;
  ++R.nextSequence;
  return true;
}

static void clientData(const KVMFRClipboardMessage * r, const uint8_t * data)
{
  if (R.state != FETCH_DATA || r->format != R.format)
    return;

  if (!acceptChunk(r, MAX_ITEM_BYTES))
  {
    DEBUG_WARN("Invalid or oversized clipboard data from the client");
    abortFetch(true);
    return;
  }

  [R.buffer appendBytes:data length:r->length];
  if (r->flags & KVMFR_CLIPBOARD_FLAG_END)
    finishData();
}

static void finishFiles(void)
{
  KVMFRClipboardMessage m = { 0 };
  m.type                = KVMFR_CLIPBOARD_MESSAGE_FILE_RELEASE;
  m.clipboardGeneration = R.generation;
  m.transfer            = R.acquireTransfer;
  m.format              = KVMFR_CLIPBOARD_FORMAT_FILES;
  sendControl(&m);

  NSArray * topLevel = R.topLevel;
  clearFiles();
  R.topLevel = [topLevel mutableCopy];
  R.state    = FETCH_IDLE;
  R.transfer = 0;
  nextStep();
}

static void nextFileOp(void)
{
  if (R.state != FETCH_FILES || R.op)
    return;

  if (!R.ops.count)
  {
    finishFiles();
    return;
  }

  NSValue * v = R.ops.firstObject;
  [R.ops removeObjectAtIndex:0];
  R.op = v.pointerValue;

  R.transfer     = newTransfer();
  R.buffer       = [NSMutableData data];
  R.nextOffset   = 0;
  R.nextSequence = 0;
  R.began        = false;

  KVMFRClipboardMessage m = { 0 };
  m.type                = KVMFR_CLIPBOARD_MESSAGE_FILE_REQUEST;
  m.clipboardGeneration = R.generation;
  m.transfer            = R.transfer;
  m.format              = KVMFR_CLIPBOARD_FORMAT_FILES;
  m.token               = R.op->operation;
  m.size                = R.op->node;
  if (R.op->operation == KVMFR_CLIPBOARD_FILE_OP_READ)
  {
    const uint64_t left = R.op->size - R.op->offset;
    m.offset = R.op->offset;
    m.flags  = left > KVMFR_CLIPBOARD_FILE_READ_BYTES ?
      KVMFR_CLIPBOARD_FILE_READ_BYTES : (uint32_t)left;

    R.fd = open(R.op->path.fileSystemRepresentation, O_WRONLY);
    if (R.fd < 0)
    {
      DEBUG_ERROR("Failed to open %s", R.op->path.UTF8String);
      abortFetch(true);
      return;
    }
  }
  sendControl(&m);
}

static bool validName(const char * name, uint32_t length)
{
  if (!length || memchr(name, '/', length) || memchr(name, 0, length))
    return false;
  if ((length == 1 && name[0] == '.') ||
      (length == 2 && name[0] == '.' && name[1] == '.'))
    return false;
  return true;
}

static void installListing(void)
{
  NSFileManager * fm = [NSFileManager defaultManager];
  const uint8_t * p = R.buffer.bytes;
  size_t left = R.buffer.length;
  const bool root = R.op->node == KVMFR_CLIPBOARD_FILE_ROOT_NODE;

  while (left >= sizeof(KVMFRClipboardFileEntry))
  {
    KVMFRClipboardFileEntry e;
    memcpy(&e, p, sizeof(e));
    const size_t bytes = KVMFR_CLIPBOARD_FILE_ENTRY_BYTES(e.nameLength);
    if (bytes > left || !validName((const char *)p + sizeof(e), e.nameLength))
      break;

    NSString * name = [[NSString alloc]
      initWithBytes:p + sizeof(e) length:e.nameLength
      encoding:NSUTF8StringEncoding];
    if (name)
    {
      NSString * path = [R.op->path stringByAppendingPathComponent:name];
      if (e.type == KVMFR_CLIPBOARD_FILE_TYPE_DIRECTORY)
      {
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES
          attributes:nil error:nil];
        queueOp(KVMFR_CLIPBOARD_FILE_OP_LIST, e.node, path, 0, 0);
      }
      else if (e.type == KVMFR_CLIPBOARD_FILE_TYPE_REGULAR)
      {
        [fm createFileAtPath:path contents:nil attributes:nil];
        if (e.size)
          queueOp(KVMFR_CLIPBOARD_FILE_OP_READ, e.node, path, e.size, 0);
      }
      if (root)
        [R.topLevel addObject:path];
    }

    p    += bytes;
    left -= bytes;
  }
}

static void fileOpDone(void)
{
  FileOp * op = R.op;
  R.op = NULL;
  R.transfer = 0;

  if (op->operation == KVMFR_CLIPBOARD_FILE_OP_LIST)
  {
    R.op = op;
    installListing();
    R.op = NULL;
  }
  else
  {
    close(R.fd);
    R.fd = -1;
    const uint64_t received = R.nextOffset;
    // a short read means the file shrank, stop there
    if (received && op->offset + received < op->size)
      queueOp(KVMFR_CLIPBOARD_FILE_OP_READ, op->node, op->path, op->size,
          op->offset + received);
  }

  freeOp(op);
  R.buffer = nil;
  nextFileOp();
}

static void clientFileData(const KVMFRClipboardMessage * r,
    const uint8_t * data)
{
  if (R.state != FETCH_FILES || !R.op || r->token != R.op->operation)
    return;

  const uint64_t limit = R.op->operation == KVMFR_CLIPBOARD_FILE_OP_READ ?
    KVMFR_CLIPBOARD_FILE_READ_BYTES : (64u << 20);
  if (!acceptChunk(r, limit))
  {
    DEBUG_WARN("Invalid file data from the client");
    abortFetch(true);
    return;
  }

  if (R.op->operation == KVMFR_CLIPBOARD_FILE_OP_READ)
  {
    if (r->length && pwrite(R.fd, data, r->length,
          (off_t)(R.op->offset + r->offset)) != (ssize_t)r->length)
    {
      DEBUG_ERROR("Failed to write %s", R.op->path.UTF8String);
      abortFetch(true);
      return;
    }
  }
  else
    [R.buffer appendBytes:data length:r->length];

  if (r->flags & KVMFR_CLIPBOARD_FLAG_END)
    fileOpDone();
}

// --- message dispatch --------------------------------------------------------

void os_clipboardMessage(const KVMFRClipboardMessage * m)
{
  @autoreleasepool
  {
    switch (m->type)
    {
      case KVMFR_CLIPBOARD_MESSAGE_OFFER:
        clientOffer(m);
        break;

      case KVMFR_CLIPBOARD_MESSAGE_CLEAR:
        abortFetch(true);
        R.generation = 0;
        R.formats    = 0;
        break;

      case KVMFR_CLIPBOARD_MESSAGE_REQUEST:
      {
        // the client pastes our clipboard
        NSData * data = nil;
        if (m->clipboardGeneration == L.generation)
        {
          if (m->format == KVMFR_CLIPBOARD_FORMAT_TEXT)
            data = L.text;
          else if (m->format == KVMFR_CLIPBOARD_FORMAT_PNG)
            data = L.png;
        }

        if (!data || !queueOutJob(false, m, m->format, data))
        {
          KVMFRClipboardMessage c = { 0 };
          c.type                = KVMFR_CLIPBOARD_MESSAGE_CANCEL;
          c.clipboardGeneration = m->clipboardGeneration;
          c.transfer            = m->transfer;
          c.format              = m->format;
          sendControl(&c);
        }
        break;
      }

      case KVMFR_CLIPBOARD_MESSAGE_CANCEL:
        dropOutTransfer(m->transfer);
        if (R.state == FETCH_DATA && m->transfer == R.transfer)
        {
          // the client cannot provide this format, try the next one
          R.state    = FETCH_IDLE;
          R.transfer = 0;
          R.buffer   = nil;
          nextStep();
        }
        break;

      case KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRE:
        clientAcquire(m);
        break;

      case KVMFR_CLIPBOARD_MESSAGE_FILE_RELEASE:
        clientReleaseAcquisition(m->transfer);
        break;

      case KVMFR_CLIPBOARD_MESSAGE_FILE_REQUEST:
        if (kvmfrClipboardTransferFromClient(m->transfer))
          serveFileRequest(m);
        break;

      case KVMFR_CLIPBOARD_MESSAGE_FILE_ACQUIRED:
        if (R.state == FETCH_ACQUIRE && m->transfer == R.acquireTransfer)
        {
          if (m->token != KVMFR_CLIPBOARD_FILE_ERROR_NONE)
          {
            DEBUG_WARN("The client refused the file transfer (%u)", m->token);
            R.acquireTransfer = 0;
            R.state = FETCH_IDLE;
            clearFiles();
            nextStep();
            break;
          }
          R.state = FETCH_FILES;
          queueOp(KVMFR_CLIPBOARD_FILE_OP_LIST, KVMFR_CLIPBOARD_FILE_ROOT_NODE,
              R.dir, 0, 0);
          nextFileOp();
        }
        break;

      case KVMFR_CLIPBOARD_MESSAGE_FILE_CANCEL:
        if (kvmfrClipboardTransferFromHelper(m->transfer))
        {
          // the client failed one of our requests or our acquisition
          if ((R.state == FETCH_FILES || R.state == FETCH_ACQUIRE) &&
              (m->transfer == R.transfer || m->transfer == R.acquireTransfer))
          {
            DEBUG_WARN("The client cancelled the file transfer (%u)", m->token);
            if (m->transfer == R.transfer)
              R.transfer = 0;
            abortFetch(m->transfer != R.acquireTransfer);
            nextStep();
          }
        }
        else
        {
          dropOutTransfer(m->transfer);
          if (hasAcquisition(m->transfer))
            clientReleaseAcquisition(m->transfer);
        }
        break;
    }
  }
}

void os_clipboardStreamData(const KVMFRClipboardMessage * record,
    const uint8_t * data)
{
  @autoreleasepool
  {
    if (record->type == KVMFR_CLIPBOARD_MESSAGE_DATA)
      clientData(record, data);
    else
      clientFileData(record, data);
  }
}

void os_clipboardOwnerChanged(bool owned)
{
  @autoreleasepool
  {
    // requests and transfers belong to one owner
    abortFetch(false);
    while (l_outCount)
      dropOutJob(0);
    l_outboxCount = 0;
    for (unsigned i = 0; i < MAX_ACQUISITIONS; ++i)
      L.acquisition[i] = 0;
    R.generation = 0;
    R.formats    = 0;
  }
}

void os_clipboardStart(void)
{
  @autoreleasepool
  {
    // unique across restarts, the client may still remember old datasets
    l_nextGeneration = (uint64_t)time(NULL) << 20;
    l_nextTransfer   = (uint64_t)time(NULL) << 20;

    // offer the current clipboard to the first client
    L.seenChange = -1;
    L.lastPoll   = 0;
    pollPasteboard();
  }
}

void os_clipboardStop(void)
{
  @autoreleasepool
  {
    os_clipboardOwnerChanged(false);
    freeNodes();
    L.text = L.png = nil;
    L.paths = nil;
  }
}

void os_clipboardTick(void)
{
  @autoreleasepool
  {
    pumpOutbox();
    pumpOutJobs();
    pollPasteboard();
  }
}
