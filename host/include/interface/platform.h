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

#pragma once

#include <stdbool.h>
#include <LGProtocol/KVMFR.h>

// exit code for user opted to exit looking-glass-host
#define LG_HOST_EXIT_USER    0x10
// exit code for capture errors that should result in a restart, e.g. UAC
#define LG_HOST_EXIT_CAPTURE 0x20
// exit code for terminated
#define LG_HOST_EXIT_KILLED  0x30
// exit code for failed to start
#define LG_HOST_EXIT_FAILED  0x40
// exit code for failed to start, and no amount of restarting could help
#define LG_HOST_EXIT_FATAL   0x50

int  app_main(int argc, char * argv[]);
bool app_init(void);
void app_shutdown(void);
void app_quit(int exitcode);

// these must be implemented for each OS
const char * os_getExecutable(void);
const char * os_getDataPath(void);
void os_showMessage(const char * caption, const char * msg);

bool os_getAndClearPendingActivationRequest(void);
bool os_blockScreensaver(void);
bool os_hasSetCursorPos(void);
void os_setCursorPos(int x, int y);

// return the KVMFR OS type
KVMFROS os_getKVMFRType(void);

// returns the OS name & version if possible
const char * os_getOSName(void);

// returns the UUID that was given to the VM, this can be obtained from the
// SMBIOS. Must return exactly 16 bytes or NULL.
const uint8_t * os_getUUID(void);

#ifdef LG_HOST_INPUT
// Input injection for KVMFR input over LGMP (see input.h).
// Buttons use the KVMFR bit layout: bit 0 left, bit 1 right, bit 2 middle,
// bit 3+ extra buttons. Absolute positions range 0..KVMFR_INPUT_MOUSE_ABSOLUTE_MAX
// across the captured display. Keyboard reports are USB HID boot reports.

// true if input can currently be injected (e.g. permission granted)
bool os_inputAvailable(void);
// release every key and button that is held down
void os_inputReset(void);
bool os_inputMouseRelative(int32_t dx, int32_t dy, int32_t wheel,
    uint32_t buttons);
bool os_inputMouseAbsolute(uint16_t x, uint16_t y, int32_t wheel,
    uint32_t buttons);
bool os_inputKeyboard(uint8_t modifiers, const uint8_t keys[6]);
// current KVMFR_INPUT_KEYBOARD_LED_* flags, false if unknown
bool os_inputKeyboardLEDs(uint8_t * leds);
#endif

#ifdef LG_HOST_CLIPBOARD
#include <LGProtocol/KVMFRClipboard.h>
// OS clipboard for KVMFR clipboard over LGMP (see clipboard.h). All of these
// are called from the clipboard worker thread.

void os_clipboardStart(void);
void os_clipboardStop(void);
// called every worker iteration: watch the OS clipboard, pump transfers
void os_clipboardTick(void);
// a client became (or stopped being) the clipboard owner
void os_clipboardOwnerChanged(bool owned);
// a validated control record from the owner (everything except CLAIM,
// RELEASE and KEEPALIVE, which the transport handles)
void os_clipboardMessage(const KVMFRClipboardMessage * message);
// a validated DATA or FILE_DATA record from the owner
void os_clipboardStreamData(const KVMFRClipboardMessage * record,
    const uint8_t * data);
#endif
