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

// Injects KVMFR input into macOS with Quartz events. Requires the
// Accessibility permission (System Settings > Privacy & Security).

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>

#include "interface/platform.h"
#include "common/debug.h"
#include "common/thread.h"
#include "common/time.h"

#include <LGProtocol/KVMFRInput.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define NO_KEY 0xFFFF

// USB HID keyboard usage -> macOS virtual key code
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winitializer-overrides"
static const uint16_t hidToKeyCode[256] =
{
  [0 ... 255] = NO_KEY,
  [0x04] = 0x00, [0x05] = 0x0B, [0x06] = 0x08, [0x07] = 0x02, // a b c d
  [0x08] = 0x0E, [0x09] = 0x03, [0x0A] = 0x05, [0x0B] = 0x04, // e f g h
  [0x0C] = 0x22, [0x0D] = 0x26, [0x0E] = 0x28, [0x0F] = 0x25, // i j k l
  [0x10] = 0x2E, [0x11] = 0x2D, [0x12] = 0x1F, [0x13] = 0x23, // m n o p
  [0x14] = 0x0C, [0x15] = 0x0F, [0x16] = 0x01, [0x17] = 0x11, // q r s t
  [0x18] = 0x20, [0x19] = 0x09, [0x1A] = 0x0D, [0x1B] = 0x07, // u v w x
  [0x1C] = 0x10, [0x1D] = 0x06,                               // y z
  [0x1E] = 0x12, [0x1F] = 0x13, [0x20] = 0x14, [0x21] = 0x15, // 1 2 3 4
  [0x22] = 0x17, [0x23] = 0x16, [0x24] = 0x1A, [0x25] = 0x1C, // 5 6 7 8
  [0x26] = 0x19, [0x27] = 0x1D,                               // 9 0
  [0x28] = 0x24, [0x29] = 0x35, [0x2A] = 0x33, [0x2B] = 0x30, // enter esc bksp tab
  [0x2C] = 0x31, [0x2D] = 0x1B, [0x2E] = 0x18, [0x2F] = 0x21, // space - = [
  [0x30] = 0x1E, [0x31] = 0x2A, [0x32] = 0x2A, [0x33] = 0x29, // ] \ non-US# ;
  [0x34] = 0x27, [0x35] = 0x32, [0x36] = 0x2B, [0x37] = 0x2F, // ' ` , .
  [0x38] = 0x2C, [0x39] = 0x39,                               // / capslock
  [0x3A] = 0x7A, [0x3B] = 0x78, [0x3C] = 0x63, [0x3D] = 0x76, // F1-F4
  [0x3E] = 0x60, [0x3F] = 0x61, [0x40] = 0x62, [0x41] = 0x64, // F5-F8
  [0x42] = 0x65, [0x43] = 0x6D, [0x44] = 0x67, [0x45] = 0x6F, // F9-F12
  [0x46] = 0x69, [0x47] = 0x6B, [0x48] = 0x71,                // prtsc scrlk pause -> F13-F15
  [0x49] = 0x72, [0x4A] = 0x73, [0x4B] = 0x74, [0x4C] = 0x75, // insert(help) home pgup del
  [0x4D] = 0x77, [0x4E] = 0x79, [0x4F] = 0x7C, [0x50] = 0x7B, // end pgdn right left
  [0x51] = 0x7D, [0x52] = 0x7E,                               // down up
  [0x53] = 0x47, [0x54] = 0x4B, [0x55] = 0x43, [0x56] = 0x4E, // numlock(clear) kp/ kp* kp-
  [0x57] = 0x45, [0x58] = 0x4C, [0x59] = 0x53, [0x5A] = 0x54, // kp+ kpenter kp1 kp2
  [0x5B] = 0x55, [0x5C] = 0x56, [0x5D] = 0x57, [0x5E] = 0x58, // kp3 kp4 kp5 kp6
  [0x5F] = 0x59, [0x60] = 0x5B, [0x61] = 0x5C, [0x62] = 0x52, // kp7 kp8 kp9 kp0
  [0x63] = 0x41, [0x64] = 0x0A, [0x67] = 0x51,                // kp. non-US\ kp=
  [0x68] = 0x69, [0x69] = 0x6B, [0x6A] = 0x71, [0x6B] = 0x6A, // F13-F16
  [0x6C] = 0x40, [0x6D] = 0x4F, [0x6E] = 0x50, [0x6F] = 0x5A, // F17-F20
  [0x7F] = 0x4A, [0x80] = 0x48, [0x81] = 0x49,                // mute vol+ vol-
  [0x85] = 0x5F, [0x87] = 0x5E, [0x89] = 0x5D,                // kp, ro yen
  [0x90] = 0x68, [0x91] = 0x66,                               // kana eisu
};
#pragma clang diagnostic pop

// HID modifier bits: LCtrl LShift LAlt LGUI RCtrl RShift RAlt RGUI
static const struct
{
  uint16_t   keyCode;
  CGEventFlags flag;   // generic flag
  CGEventFlags device; // left/right specific NX_DEVICE* bit
}
modifierInfo[8] =
{
  { 0x3B, kCGEventFlagMaskControl  , 0x00000001 },
  { 0x38, kCGEventFlagMaskShift    , 0x00000002 },
  { 0x3A, kCGEventFlagMaskAlternate, 0x00000020 },
  { 0x37, kCGEventFlagMaskCommand  , 0x00000008 },
  { 0x3E, kCGEventFlagMaskControl  , 0x00002000 },
  { 0x3C, kCGEventFlagMaskShift    , 0x00000004 },
  { 0x3D, kCGEventFlagMaskAlternate, 0x00000040 },
  { 0x36, kCGEventFlagMaskCommand  , 0x00000010 },
};

#define CAPS_LOCK_USAGE 0x39

static struct
{
  pthread_mutex_t    lock;
  bool               initialized;
  CGEventSourceRef   source;

  uint64_t           lastTrustCheck;
  bool               trusted;

  // mouse
  CGPoint            pos;       // global points
  bool               posValid;
  uint32_t           buttons;
  int                clickCount;
  int                clickButton;
  uint64_t           clickTime;
  CGPoint            clickPos;

  // keyboard
  uint8_t            modifiers;
  uint8_t            keys[KVMFR_INPUT_KEYBOARD_KEY_COUNT];

  // software key repeat, macOS does not repeat posted key events
  uint16_t           repeatKey;
  uint64_t           repeatNext;
  LGThread         * repeatThread;
  atomic_bool        repeatStop;
}
l = { .lock = PTHREAD_MUTEX_INITIALIZER, .repeatKey = NO_KEY };

static int repeatThread(void * opaque);

// LSUIElement apps have no visible window, so App Nap would throttle their
// timers by hundreds of milliseconds. Hold a latency-critical activity for the
// lifetime of the process.
static id l_activity;

void darwin_disableAppNap(void)
{
  l_activity = [[NSProcessInfo processInfo]
    beginActivityWithOptions:NSActivityLatencyCritical |
      NSActivityUserInitiatedAllowingIdleSystemSleep
    reason:@"Looking Glass capture and input"];
}

static void initNL(void)
{
  if (l.initialized)
    return;

  l.source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  // post events immediately, do not suppress local hardware events
  CGEventSourceSetLocalEventsSuppressionInterval(l.source, 0.0);

  // ask for Accessibility permission once, adds us to the settings list
  NSDictionary * opts = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES };
  l.trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
  l.lastTrustCheck = microtime();
  if (!l.trusted)
    DEBUG_WARN("Accessibility permission is required for input: enable "
        "\"Looking Glass Host\" in System Settings > Privacy & Security > "
        "Accessibility");

  atomic_store(&l.repeatStop, false);
  lgCreateThread("KeyRepeat", repeatThread, NULL, &l.repeatThread);

  l.initialized = true;
}

static CGEventFlags currentFlagsNL(void)
{
  CGEventFlags flags = 0;
  for (int i = 0; i < 8; ++i)
    if (l.modifiers & (1 << i))
      flags |= modifierInfo[i].flag | modifierInfo[i].device;

  if (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) &
      kCGEventFlagMaskAlphaShift)
    flags |= kCGEventFlagMaskAlphaShift;
  return flags;
}

static void displayGeometry(CGRect * bounds, double * scale)
{
  const CGDirectDisplayID display = CGMainDisplayID();
  *bounds = CGDisplayBounds(display);
  *scale  = bounds->size.width > 0 ?
    (double)CGDisplayPixelsWide(display) / bounds->size.width : 1.0;
}

bool os_inputAvailable(void)
{
  pthread_mutex_lock(&l.lock);
  initNL();

  // re-check every second so granting the permission takes effect live
  const uint64_t now = microtime();
  if (now - l.lastTrustCheck > 1000000)
  {
    l.trusted        = AXIsProcessTrusted();
    l.lastTrustCheck = now;
  }

  const bool trusted = l.trusted;
  pthread_mutex_unlock(&l.lock);
  return trusted;
}

static void postKeyNL(uint16_t keyCode, bool down, bool autorepeat)
{
  CGEventRef ev = CGEventCreateKeyboardEvent(l.source, keyCode, down);
  CGEventSetFlags(ev, currentFlagsNL());
  if (autorepeat)
    CGEventSetIntegerValueField(ev, kCGKeyboardEventAutorepeat, 1);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

static void toggleCapsLockNL(void)
{
  // posted caps lock key events do not change the lock state, set it directly
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
      IOServiceMatching(kIOHIDSystemClass));
  if (!svc)
    return;

  io_connect_t conn;
  if (IOServiceOpen(svc, mach_task_self(), kIOHIDParamConnectType, &conn) ==
      KERN_SUCCESS)
  {
    bool state = false;
    IOHIDGetModifierLockState(conn, kIOHIDCapsLockState, &state);
    IOHIDSetModifierLockState(conn, kIOHIDCapsLockState, !state);
    IOServiceClose(conn);
  }
  IOObjectRelease(svc);
}

// --- mouse -----------------------------------------------------------------

static CGEventType moveTypeNL(CGMouseButton * button)
{
  if (l.buttons & 1)
  {
    *button = kCGMouseButtonLeft;
    return kCGEventLeftMouseDragged;
  }
  if (l.buttons & 2)
  {
    *button = kCGMouseButtonRight;
    return kCGEventRightMouseDragged;
  }
  if (l.buttons)
  {
    *button = kCGMouseButtonCenter;
    return kCGEventOtherMouseDragged;
  }
  *button = kCGMouseButtonLeft;
  return kCGEventMouseMoved;
}

static void postMoveNL(double dx, double dy)
{
  CGMouseButton button;
  const CGEventType type = moveTypeNL(&button);
  CGEventRef ev = CGEventCreateMouseEvent(l.source, type, l.pos, button);
  CGEventSetFlags(ev, currentFlagsNL());
  CGEventSetIntegerValueField(ev, kCGMouseEventDeltaX, (int64_t)dx);
  CGEventSetIntegerValueField(ev, kCGMouseEventDeltaY, (int64_t)dy);
  if (l.buttons)
    CGEventSetIntegerValueField(ev, kCGMouseEventClickState, l.clickCount);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

// KVMFR button bit -> macOS mouse button number, -1 for none
static int macButton(int bit)
{
  switch (bit)
  {
    case 0: return kCGMouseButtonLeft;
    case 1: return kCGMouseButtonRight;
    case 2: return kCGMouseButtonCenter;
    case 3: case 4: return -1;  // horizontal scroll, handled separately
    case 5: return 3;           // back
    case 6: return 4;           // forward
    default: return bit;
  }
}

static void postButtonsNL(uint32_t buttons)
{
  const uint32_t changed = buttons ^ l.buttons;
  if (!changed)
    return;

  for (int bit = 0; bit < 32; ++bit)
  {
    if (!(changed & (1u << bit)))
      continue;

    const bool down = buttons & (1u << bit);

    // X11 buttons 6/7 arrive as buttons, they are horizontal scrolling
    if (bit == 3 || bit == 4)
    {
      if (down)
      {
        CGEventRef ev = CGEventCreateScrollWheelEvent(l.source,
            kCGScrollEventUnitLine, 2, 0, bit == 3 ? 1 : -1);
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
      }
      continue;
    }

    const int button = macButton(bit);
    CGEventType type;
    switch (button)
    {
      case kCGMouseButtonLeft:
        type = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
        break;
      case kCGMouseButtonRight:
        type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
        break;
      default:
        type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
        break;
    }

    if (down)
    {
      // macOS does not count clicks for posted events, do it here
      const uint64_t now = microtime();
      const double interval = [NSEvent doubleClickInterval] * 1e6;
      if (button == l.clickButton &&
          now - l.clickTime <= interval &&
          fabs(l.pos.x - l.clickPos.x) <= 4 &&
          fabs(l.pos.y - l.clickPos.y) <= 4)
        ++l.clickCount;
      else
        l.clickCount = 1;
      l.clickButton = button;
      l.clickTime   = now;
      l.clickPos    = l.pos;
    }

    CGEventRef ev = CGEventCreateMouseEvent(l.source, type, l.pos,
        (CGMouseButton)button);
    CGEventSetFlags(ev, currentFlagsNL());
    CGEventSetIntegerValueField(ev, kCGMouseEventClickState,
        button == l.clickButton ? l.clickCount : 1);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);

    if (down)
      l.buttons |= 1u << bit;
    else
      l.buttons &= ~(1u << bit);
  }

  l.buttons = buttons;
}

static void postWheelNL(int32_t wheel)
{
  if (!wheel)
    return;

  CGEventRef ev = CGEventCreateScrollWheelEvent(l.source,
      kCGScrollEventUnitLine, 1, wheel);
  CGEventSetFlags(ev, currentFlagsNL());
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

static void syncPosNL(void)
{
  if (l.posValid)
    return;

  CGEventRef ev = CGEventCreate(NULL);
  l.pos = CGEventGetLocation(ev);
  CFRelease(ev);
  l.posValid = true;
}

bool os_inputMouseRelative(int32_t dx, int32_t dy, int32_t wheel,
    uint32_t buttons)
{
  pthread_mutex_lock(&l.lock);
  initNL();
  syncPosNL();

  if (dx || dy)
  {
    CGRect bounds;
    double scale;
    displayGeometry(&bounds, &scale);

    double x = l.pos.x + dx / scale;
    double y = l.pos.y + dy / scale;
    x = fmax(CGRectGetMinX(bounds), fmin(x, CGRectGetMaxX(bounds) - 1));
    y = fmax(CGRectGetMinY(bounds), fmin(y, CGRectGetMaxY(bounds) - 1));
    l.pos = CGPointMake(x, y);
    postMoveNL(dx, dy);
  }

  postButtonsNL(buttons);
  postWheelNL(wheel);
  pthread_mutex_unlock(&l.lock);
  return true;
}

bool os_inputMouseAbsolute(uint16_t x, uint16_t y, int32_t wheel,
    uint32_t buttons)
{
  pthread_mutex_lock(&l.lock);
  initNL();
  syncPosNL();

  CGRect bounds;
  double scale;
  displayGeometry(&bounds, &scale);

  // the client maps 0..MAX onto 0..(pixels - 1) of the captured frame
  const double pxW = bounds.size.width  * scale;
  const double pxH = bounds.size.height * scale;
  const CGPoint pos = CGPointMake(
    bounds.origin.x + x * (pxW - 1) / KVMFR_INPUT_MOUSE_ABSOLUTE_MAX / scale,
    bounds.origin.y + y * (pxH - 1) / KVMFR_INPUT_MOUSE_ABSOLUTE_MAX / scale);

  if (pos.x != l.pos.x || pos.y != l.pos.y)
  {
    const double dx = (pos.x - l.pos.x) * scale;
    const double dy = (pos.y - l.pos.y) * scale;
    l.pos = pos;
    postMoveNL(dx, dy);
  }

  postButtonsNL(buttons);
  postWheelNL(wheel);
  pthread_mutex_unlock(&l.lock);
  return true;
}

// --- keyboard --------------------------------------------------------------

static bool keyInReport(const uint8_t keys[6], uint8_t usage)
{
  for (int i = 0; i < KVMFR_INPUT_KEYBOARD_KEY_COUNT; ++i)
    if (keys[i] == usage)
      return true;
  return false;
}

static void startRepeatNL(uint16_t keyCode)
{
  // InitialKeyRepeat / KeyRepeat are in units of 15 ms
  NSUserDefaults * d = [NSUserDefaults standardUserDefaults];
  const NSInteger initial = [d integerForKey:@"InitialKeyRepeat"] ?: 25;
  l.repeatKey  = keyCode;
  l.repeatNext = microtime() + (uint64_t)initial * 15000;
}

bool os_inputKeyboard(uint8_t modifiers, const uint8_t keys[6])
{
  pthread_mutex_lock(&l.lock);
  initNL();

  // releases first, then modifier changes, then presses
  for (int i = 0; i < KVMFR_INPUT_KEYBOARD_KEY_COUNT; ++i)
  {
    const uint8_t usage = l.keys[i];
    if (!usage || keyInReport(keys, usage))
      continue;

    const uint16_t kc = hidToKeyCode[usage];
    if (kc == NO_KEY || usage == CAPS_LOCK_USAGE)
      continue;
    postKeyNL(kc, false, false);
    if (kc == l.repeatKey)
      l.repeatKey = NO_KEY;
  }

  const uint8_t changed = modifiers ^ l.modifiers;
  for (int i = 0; i < 8; ++i)
  {
    if (!(changed & (1 << i)))
      continue;

    l.modifiers ^= 1 << i;
    CGEventRef ev = CGEventCreateKeyboardEvent(l.source,
        modifierInfo[i].keyCode, (modifiers & (1 << i)) != 0);
    CGEventSetType(ev, kCGEventFlagsChanged);
    CGEventSetFlags(ev, currentFlagsNL());
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
  }

  for (int i = 0; i < KVMFR_INPUT_KEYBOARD_KEY_COUNT; ++i)
  {
    const uint8_t usage = keys[i];
    if (!usage || keyInReport(l.keys, usage))
      continue;

    if (usage == CAPS_LOCK_USAGE)
    {
      toggleCapsLockNL();
      continue;
    }

    const uint16_t kc = hidToKeyCode[usage];
    if (kc == NO_KEY)
      continue;
    postKeyNL(kc, true, false);
    startRepeatNL(kc);
  }

  memcpy(l.keys, keys, sizeof(l.keys));
  pthread_mutex_unlock(&l.lock);
  return true;
}

static int repeatThread(void * opaque)
{
  while (!atomic_load(&l.repeatStop))
  {
    pthread_mutex_lock(&l.lock);
    const uint64_t now = microtime();
    if (l.repeatKey != NO_KEY && now >= l.repeatNext)
    {
      postKeyNL(l.repeatKey, true, true);
      NSInteger rate = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"KeyRepeat"] ?: 6;
      l.repeatNext = now + (uint64_t)rate * 15000;
    }
    pthread_mutex_unlock(&l.lock);
    usleep(2000);
  }
  return 0;
}

bool os_inputKeyboardLEDs(uint8_t * leds)
{
  *leds = (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) &
      kCGEventFlagMaskAlphaShift) ? KVMFR_INPUT_KEYBOARD_LED_CAPS_LOCK : 0;
  return true;
}

void os_inputReset(void)
{
  pthread_mutex_lock(&l.lock);
  if (!l.initialized)
  {
    pthread_mutex_unlock(&l.lock);
    return;
  }

  static const uint8_t none[KVMFR_INPUT_KEYBOARD_KEY_COUNT] = { 0 };
  pthread_mutex_unlock(&l.lock);

  os_inputKeyboard(0, none);

  pthread_mutex_lock(&l.lock);
  l.repeatKey = NO_KEY;
  postButtonsNL(0);
  // the cursor may be moved locally between owners, re-read it next time
  l.posValid = false;
  pthread_mutex_unlock(&l.lock);
}
