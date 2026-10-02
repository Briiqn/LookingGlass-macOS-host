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

// ScreenCaptureKit capture for a macOS guest.
//
// Synchronous capture: capture() blocks until ScreenCaptureKit delivers a new
// complete frame (or times out), waitFrame() describes it and getFrame()
// copies it straight into the KVMFR frame buffer in shared memory.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "interface/capture.h"
#include "interface/platform.h"
#include "common/debug.h"
#include "common/event.h"
#include "common/thread.h"
#include "common/option.h"
#include "common/util.h"

#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>

struct sck
{
  bool               initialized;
  atomic_bool        stopped;     // the stream stopped on its own (error / display change)
  LGEvent          * frameEvent;  // signalled when a new frame is pending

  pthread_mutex_t    lock;
  CVPixelBufferRef   pending;     // newest frame from ScreenCaptureKit
  CVPixelBufferRef   current;     // frame being sent

  unsigned           width, height, pitch;
  unsigned           formatVer;

  SCStream         * stream;
  id                 output;
  dispatch_queue_t   queue;

  CaptureGetPointerBuffer  getPointerBufferFn;
  CapturePostPointerBuffer postPointerBufferFn;
  LGThread               * pointerThread;
  atomic_bool              pointerStop;

  CGRect             displayBounds; // in points, global coordinates
  double             scale;         // pixels per point
};

static struct sck * this = NULL;

@interface LGStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@end

@implementation LGStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type
{
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer))
    return;

  // Only complete frames carry new pixels; idle frames repeat the last one.
  CFArrayRef attachments =
    CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (!attachments || CFArrayGetCount(attachments) == 0)
    return;

  NSDictionary * info = (__bridge NSDictionary *)
    CFArrayGetValueAtIndex(attachments, 0);
  NSNumber * status = info[SCStreamFrameInfoStatus];
  if (!status || status.integerValue != SCFrameStatusComplete)
    return;

  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pb)
    return;

  CVPixelBufferRetain(pb);
  pthread_mutex_lock(&this->lock);
  CVPixelBufferRef old = this->pending;
  this->pending = pb;
  pthread_mutex_unlock(&this->lock);
  if (old)
    CVPixelBufferRelease(old);

  lgSignalEvent(this->frameEvent);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
  DEBUG_WARN("ScreenCaptureKit stream stopped: %s",
      error.localizedDescription.UTF8String);
  atomic_store(&this->stopped, true);
  lgSignalEvent(this->frameEvent);
}

@end

static bool sck_deinit(void);

static const char * sck_getName(void)
{
  return "ScreenCaptureKit";
}

static void sck_initOptions(void)
{
  struct Option options[] =
  {
    {
      .module       = "sck",
      .name         = "display",
      .description  = "The CGDirectDisplayID to capture (0 = main display)",
      .type         = OPTION_TYPE_INT,
      .value.x_int  = 0
    },
    {0}
  };

  option_register(options);
}

static bool sck_create(
  CaptureGetPointerBuffer  getPointerBufferFn,
  CapturePostPointerBuffer postPointerBufferFn,
  unsigned                 frameBuffers)
{
  DEBUG_ASSERT(!this);
  this = calloc(1, sizeof(*this));
  if (!this)
  {
    DEBUG_ERROR("out of memory");
    return false;
  }

  this->frameEvent = lgCreateEvent(true, 0);
  if (!this->frameEvent)
  {
    DEBUG_ERROR("Failed to create the frame event");
    free(this);
    this = NULL;
    return false;
  }

  this->getPointerBufferFn  = getPointerBufferFn;
  this->postPointerBufferFn = postPointerBufferFn;

  pthread_mutex_init(&this->lock, NULL);
  return true;
}

static SCShareableContent * getShareableContent(void)
{
  __block SCShareableContent * result = nil;
  __block NSError * err = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  [SCShareableContent
    getShareableContentExcludingDesktopWindows:NO
    onScreenWindowsOnly:YES
    completionHandler:^(SCShareableContent * content, NSError * error)
    {
      result = content;
      err    = error;
      dispatch_semaphore_signal(done);
    }];

  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  if (!result)
    DEBUG_ERROR("Unable to list displays (is Screen Recording permission "
        "granted?): %s", err.localizedDescription.UTF8String);
  return result;
}

static bool sck_init(void * ivshmemBase, unsigned * alignSize)
{
  DEBUG_ASSERT(this);
  DEBUG_ASSERT(!this->initialized);

  atomic_store(&this->stopped, false);
  lgResetEvent(this->frameEvent);

  // ScreenCaptureKit never prompts on its own, this adds the app to
  // System Settings > Privacy & Security > Screen Recording.
  if (!CGPreflightScreenCaptureAccess())
  {
    CGRequestScreenCaptureAccess();
    DEBUG_ERROR("Screen Recording permission is required: enable "
        "\"Looking Glass Host\" in System Settings > Privacy & Security > "
        "Screen & System Audio Recording, then start it again");
    return false;
  }

  @autoreleasepool
  {
    SCShareableContent * content = getShareableContent();
    if (!content)
      return false;

    CGDirectDisplayID wantID = (CGDirectDisplayID)option_get_int("sck", "display");
    if (!wantID)
      wantID = CGMainDisplayID();

    SCDisplay * display = nil;
    for (SCDisplay * d in content.displays)
      if (d.displayID == wantID)
      {
        display = d;
        break;
      }

    if (!display)
    {
      DEBUG_ERROR("Display %u not found", wantID);
      return false;
    }

    // capture at the display's native pixel size, not its point size
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display.displayID);
    size_t width   = mode ? CGDisplayModeGetPixelWidth (mode) : display.width;
    size_t height  = mode ? CGDisplayModeGetPixelHeight(mode) : display.height;
    double refresh = mode ? CGDisplayModeGetRefreshRate(mode) : 0.0;
    if (mode)
      CGDisplayModeRelease(mode);
    if (refresh < 1.0)
      refresh = 60.0;

    this->displayBounds = CGDisplayBounds(display.displayID);
    this->scale = this->displayBounds.size.width > 0 ?
      (double)width / this->displayBounds.size.width : 1.0;

    SCContentFilter * filter = [[SCContentFilter alloc]
      initWithDisplay:display excludingWindows:@[]];

    SCStreamConfiguration * cfg = [[SCStreamConfiguration alloc] init];
    cfg.width                = width;
    cfg.height               = height;
    cfg.pixelFormat          = kCVPixelFormatType_32BGRA;
    cfg.colorSpaceName       = kCGColorSpaceSRGB;
    // the cursor is sent separately so the client can draw it with no delay
    cfg.showsCursor          = NO;
    cfg.scalesToFit          = NO;
    cfg.queueDepth           = 4;
    // the default is 60 fps, allow one frame per display refresh
    cfg.minimumFrameInterval = CMTimeMake(1, (int32_t)(refresh + 0.5));

    this->queue = dispatch_queue_create("lg.sck.output",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
          QOS_CLASS_USER_INTERACTIVE, 0));

    LGStreamOutput * output = [[LGStreamOutput alloc] init];
    SCStream * stream = [[SCStream alloc]
      initWithFilter:filter configuration:cfg delegate:output];

    NSError * err = nil;
    if (![stream addStreamOutput:output type:SCStreamOutputTypeScreen
        sampleHandlerQueue:this->queue error:&err])
    {
      DEBUG_ERROR("addStreamOutput failed: %s",
          err.localizedDescription.UTF8String);
      return false;
    }

    __block NSError * startErr = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [stream startCaptureWithCompletionHandler:^(NSError * error)
    {
      startErr = error;
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    if (startErr)
    {
      DEBUG_ERROR("Failed to start capture: %s",
          startErr.localizedDescription.UTF8String);
      return false;
    }

    this->stream = stream;
    this->output = output;

    DEBUG_INFO("Display          : %u", display.displayID);
    DEBUG_INFO("Frame Size       : %zu x %zu @ %.0f Hz", width, height, refresh);
  }

  this->initialized = true;
  return true;
}

static int pointerThread(void * unused);

static bool sck_start(void)
{
  // The pointer thread is started by the first capture() call: the app also
  // starts the backend once at launch to probe it, before the pointer buffers
  // in shared memory exist.
  atomic_store(&this->pointerStop, false);
  return true;
}

static void sck_stop(void)
{
  atomic_store(&this->pointerStop, true);
  if (this->pointerThread)
  {
    lgJoinThread(this->pointerThread, NULL);
    this->pointerThread = NULL;
  }

  // wake capture() so the app can shut down
  lgSignalEvent(this->frameEvent);
}

// Renders the current system cursor as premultiplied BGRA into the pointer
// buffer. Returns false if the shape is unchanged since the last call.
static bool readCursorShape(CapturePointer * pointer, void * data,
    uint32_t size, uint64_t * lastHash)
{
  @autoreleasepool
  {
    NSCursor * cursor = [NSCursor currentSystemCursor];
    if (!cursor)
      return false;

    NSImage * image = cursor.image;
    NSPoint   hot   = cursor.hotSpot;
    const unsigned w = (unsigned)(image.size.width  * this->scale + 0.5);
    const unsigned h = (unsigned)(image.size.height * this->scale + 0.5);
    const unsigned pitch = w * 4;
    if (!w || !h || (uint64_t)pitch * h > size)
      return false;

    NSRect rect = NSMakeRect(0, 0, w, h);
    CGImageRef cg = [image CGImageForProposedRect:&rect context:nil hints:nil];
    if (!cg)
      return false;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, pitch, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx)
      return false;

    CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);

    // FNV-1a over the pixels and hotspot to detect shape changes
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t * p = data;
    for (size_t i = 0; i < (size_t)pitch * h; ++i)
      hash = (hash ^ p[i]) * 1099511628211ULL;
    hash ^= ((uint64_t)w << 48) ^ ((uint64_t)h << 32) ^
      ((uint64_t)(unsigned)(hot.x * this->scale) << 16) ^
      (uint64_t)(unsigned)(hot.y * this->scale);

    if (hash == *lastHash)
      return false;
    *lastHash = hash;

    pointer->shapeUpdate = true;
    pointer->format      = CAPTURE_FMT_COLOR;
    pointer->width       = w;
    pointer->height      = h;
    pointer->pitch       = pitch;
    pointer->hx          = (unsigned)(hot.x * this->scale + 0.5);
    pointer->hy          = (unsigned)(hot.y * this->scale + 0.5);
    return true;
  }
}

static int pointerThread(void * unused)
{
  int      lastX = INT32_MIN, lastY = INT32_MIN;
  unsigned hx = 0, hy = 0;
  uint64_t lastHash = 0;
  unsigned tick = 0;

  while (!atomic_load(&this->pointerStop))
  {
    CapturePointer pointer = { 0 };

    // the shape changes rarely, check it every 8 ms
    if ((tick++ & 7) == 0)
    {
      void   * data;
      uint32_t size;
      if (this->getPointerBufferFn(&data, &size) &&
          readCursorShape(&pointer, data, size, &lastHash))
      {
        hx = pointer.hx;
        hy = pointer.hy;
      }
    }

    CGEventRef ev = CGEventCreate(NULL);
    CGPoint loc = CGEventGetLocation(ev);
    CFRelease(ev);

    const int x = (int)((loc.x - this->displayBounds.origin.x) * this->scale) - hx;
    const int y = (int)((loc.y - this->displayBounds.origin.y) * this->scale) - hy;
    if (x != lastX || y != lastY || pointer.shapeUpdate)
    {
      pointer.positionUpdate = true;
      pointer.x = lastX = x;
      pointer.y = lastY = y;
    }

    if (pointer.positionUpdate || pointer.shapeUpdate)
    {
      pointer.visible = true;
      if (!pointer.shapeUpdate)
      {
        pointer.hx = hx;
        pointer.hy = hy;
      }
      this->postPointerBufferFn(&pointer);
    }

    usleep(1000);
  }

  return 0;
}

static bool sck_deinit(void)
{
  DEBUG_ASSERT(this);

  if (this->stream)
  {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [this->stream stopCaptureWithCompletionHandler:^(NSError * error)
    {
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    this->stream = nil;
    this->output = nil;
  }

  // drain any callback still running on the output queue
  if (this->queue)
  {
    dispatch_sync(this->queue, ^{});
    this->queue = nil;
  }

  pthread_mutex_lock(&this->lock);
  if (this->pending)
    CVPixelBufferRelease(this->pending);
  if (this->current)
    CVPixelBufferRelease(this->current);
  this->pending = NULL;
  this->current = NULL;
  pthread_mutex_unlock(&this->lock);

  this->initialized = false;
  return true;
}

static void sck_free(void)
{
  lgFreeEvent(this->frameEvent);
  pthread_mutex_destroy(&this->lock);
  free(this);
  this = NULL;
}

static CaptureResult sck_capture(
  unsigned frameBufferIndex,
  KVMFRFrameBuffer * frame)
{
  DEBUG_ASSERT(this);
  DEBUG_ASSERT(this->initialized);

  if (!this->pointerThread &&
      !lgCreateThread("SCKPointer", pointerThread, NULL, &this->pointerThread))
  {
    DEBUG_ERROR("Failed to create the pointer thread");
    return CAPTURE_RESULT_ERROR;
  }

  if (!lgWaitEvent(this->frameEvent, 100))
    return CAPTURE_RESULT_TIMEOUT;

  if (atomic_load(&this->stopped))
    return CAPTURE_RESULT_REINIT;

  pthread_mutex_lock(&this->lock);
  CVPixelBufferRef pb = this->pending;
  this->pending = NULL;
  pthread_mutex_unlock(&this->lock);

  if (!pb)
    return CAPTURE_RESULT_TIMEOUT;

  if (this->current)
    CVPixelBufferRelease(this->current);
  this->current = pb;
  return CAPTURE_RESULT_OK;
}

static CaptureResult sck_waitFrame(
  unsigned       frameBufferIndex,
  CaptureFrame * frame,
  const size_t   maxFrameSize)
{
  CVPixelBufferRef pb = this->current;
  if (!pb)
    return CAPTURE_RESULT_TIMEOUT;

  const unsigned width  = (unsigned)CVPixelBufferGetWidth(pb);
  const unsigned height = (unsigned)CVPixelBufferGetHeight(pb);
  const unsigned pitch  = (unsigned)CVPixelBufferGetBytesPerRow(pb);

  if (width != this->width || height != this->height || pitch != this->pitch)
  {
    this->width  = width;
    this->height = height;
    this->pitch  = pitch;
    ++this->formatVer;
  }

  const unsigned maxHeight = maxFrameSize / pitch;

  frame->formatVer    = this->formatVer;
  frame->screenWidth  = width;
  frame->screenHeight = height;
  frame->dataWidth    = width;
  frame->dataHeight   = min(maxHeight, height);
  frame->frameWidth   = width;
  frame->frameHeight  = height;
  frame->truncated    = maxHeight < height;
  frame->pitch        = pitch;
  frame->stride       = pitch / 4;
  frame->format       = CAPTURE_FMT_BGRA;
  frame->rotation     = CAPTURE_ROT_0;
  frame->damageRectsCount = 0;

  return CAPTURE_RESULT_OK;
}

static CaptureResult sck_getFrame(
  unsigned           frameBufferIndex,
  KVMFRFrameBuffer * frame,
  const size_t       maxFrameSize,
  CaptureFrame     * captureFrame)
{
  CVPixelBufferRef pb = this->current;
  if (!pb)
    return CAPTURE_RESULT_ERROR;

  if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) !=
      kCVReturnSuccess)
  {
    DEBUG_ERROR("Failed to lock the pixel buffer");
    return CAPTURE_RESULT_ERROR;
  }

  const unsigned maxHeight = maxFrameSize / this->pitch;
  const unsigned height    = min(maxHeight, this->height);
  framebuffer_write(frame, CVPixelBufferGetBaseAddress(pb),
      (size_t)this->pitch * height);

  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  return CAPTURE_RESULT_OK;
}

struct CaptureInterface Capture_ScreenCaptureKit =
{
  .shortName    = "SCK",
  .asyncCapture = false,
  .getName      = sck_getName,
  .initOptions  = sck_initOptions,
  .create       = sck_create,
  .init         = sck_init,
  .start        = sck_start,
  .stop         = sck_stop,
  .deinit       = sck_deinit,
  .free         = sck_free,
  .capture      = sck_capture,
  .waitFrame    = sck_waitFrame,
  .getFrame     = sck_getFrame
};
