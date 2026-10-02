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

// macOS guest: the IVSHMEM BAR is exposed by the LGIVSHMEM kext, which maps
// it into this process through an IOUserClient.

#include "common/ivshmem.h"

#include <IOKit/IOKitLib.h>
#include <stdlib.h>

#include "common/debug.h"

#define LG_IVSHMEM_SERVICE "LGIVSHMEM"

struct IVSHMEMInfo
{
  io_connect_t      conn;
  mach_vm_address_t addr;
};

void ivshmemOptionsInit(void)
{
}

bool ivshmemInit(struct IVSHMEM * dev)
{
  return true;
}

bool ivshmemOpen(struct IVSHMEM * dev)
{
  return ivshmemOpenDev(dev, LG_IVSHMEM_SERVICE);
}

bool ivshmemOpenDev(struct IVSHMEM * dev, const char * shmDevice)
{
  DEBUG_ASSERT(dev);
  dev->opaque = NULL;

  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
      IOServiceMatching(shmDevice));
  if (!svc)
  {
    DEBUG_ERROR("The %s service was not found, is the LGIVSHMEM kext loaded?",
        shmDevice);
    return false;
  }

  io_connect_t conn;
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
  IOObjectRelease(svc);
  if (kr != KERN_SUCCESS)
  {
    DEBUG_ERROR("IOServiceOpen failed: 0x%x", kr);
    return false;
  }

  // Write combining: the host only streams frames into this memory, and a
  // cached or uncached mapping is several times slower for that.
  mach_vm_address_t addr = 0;
  mach_vm_size_t    size = 0;
  kr = IOConnectMapMemory64(conn, 0, mach_task_self(), &addr, &size,
      kIOMapAnywhere | kIOMapWriteCombineCache);
  if (kr != KERN_SUCCESS)
  {
    DEBUG_ERROR("IOConnectMapMemory64 failed: 0x%x", kr);
    IOServiceClose(conn);
    return false;
  }

  struct IVSHMEMInfo * info = malloc(sizeof(*info));
  info->conn = conn;
  info->addr = addr;

  DEBUG_INFO("KVMFR Device     : %s", shmDevice);
  DEBUG_INFO("IVSHMEM Size     : %llu MiB", (unsigned long long)size >> 20);

  dev->opaque = info;
  dev->size   = (unsigned int)size;
  dev->mem    = (void *)addr;
  return true;
}

void ivshmemClose(struct IVSHMEM * dev)
{
  DEBUG_ASSERT(dev);

  if (!dev->opaque)
    return;

  struct IVSHMEMInfo * info = (struct IVSHMEMInfo *)dev->opaque;
  IOConnectUnmapMemory64(info->conn, 0, mach_task_self(), info->addr);
  IOServiceClose(info->conn);
  free(info);

  dev->size   = 0;
  dev->mem    = NULL;
  dev->opaque = NULL;
}

void ivshmemFree(struct IVSHMEM * dev)
{
}

bool ivshmemHasDMA(struct IVSHMEM * dev)
{
  return false;
}

int ivshmemGetDMABuf(struct IVSHMEM * dev, uint64_t offset, uint64_t size)
{
  return -1;
}
