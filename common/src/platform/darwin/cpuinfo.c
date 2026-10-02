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

#include "common/cpuinfo.h"
#include "common/debug.h"

#include <stdio.h>
#include <sys/sysctl.h>

static int sysctlInt(const char * name)
{
  int value = 0;
  size_t len = sizeof(value);
  if (sysctlbyname(name, &value, &len, NULL, 0) != 0)
    return 0;
  return value;
}

bool cpuInfo_get(char * model, size_t modelSize, int * procs, int * cores,
  int * sockets)
{
  if (model)
  {
    size_t len = modelSize;
    if (sysctlbyname("machdep.cpu.brand_string", model, &len, NULL, 0) != 0)
      snprintf(model, modelSize, "Unknown");
  }

  if (procs)
    *procs = sysctlInt("hw.logicalcpu");

  if (cores)
    *cores = sysctlInt("hw.physicalcpu");

  if (sockets)
    *sockets = sysctlInt("hw.packages");

  return true;
}
