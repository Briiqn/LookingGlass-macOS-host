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

// KVMFR clipboard over LGMP: the host (guest OS) side of the LGMP clipboard
// transport, adapted from the Windows IDD's CLGMPClipboardTransport. The OS
// clipboard itself is handled by the platform through the os_clipboard*
// functions, which are all called from the clipboard worker thread.

#include <stdbool.h>
#include <stdint.h>
#include "lgmp/host.h"
#include <LGProtocol/KVMFRClipboard.h>

// Creates the clipboard queue, streams and memory. Must be called after
// lgmpHostInit and before the frame buffers take the remaining memory.
bool clipboardHost_setup(PLGMPHost host);
bool clipboardHost_start(void);
void clipboardHost_stop(void);
void clipboardHost_free(void);

typedef enum
{
  CLIPBOARD_SENT,     // delivered (or cached for the next owner)
  CLIPBOARD_BUSY,     // try again later
  CLIPBOARD_NO_OWNER  // dropped, no client owns the clipboard
}
ClipboardSendResult;

// Called from the platform (clipboard worker thread only). The generation
// field is filled in by the transport.

// OFFER, CLEAR, REQUEST, CANCEL and the FILE_* control records. OFFER and
// CLEAR are cached and replayed to the next owner.
ClipboardSendResult clipboardHost_sendControl(KVMFRClipboardMessage * record);

// DATA and FILE_DATA records with their payload (record->length bytes).
ClipboardSendResult clipboardHost_sendStream(KVMFRClipboardMessage * record,
    const void * data);

bool clipboardHost_hasOwner(void);
