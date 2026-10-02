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

// KVMFR input over LGMP (the client -> host input streams), a C port of the
// Windows IDD's CLGMPInputTransport. Received input is delivered through the
// os_input* functions of the platform.

#include <stdbool.h>
#include "lgmp/host.h"

// Creates the input queue, streams and status memory. Must be called after
// lgmpHostInit and before the frame buffers take the remaining memory.
bool inputHost_setup(PLGMPHost host);

// Starts and stops the worker thread that drains the input streams.
bool inputHost_start(void);
void inputHost_stop(void);

// Stops the worker and frees all LGMP resources.
void inputHost_free(void);
