# Process Filesystem (procfs)

procfs exposes process information through a filesystem interface at `/proc`.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/procfs/` (~3,800 lines)

procfs provides:

- **Process information** — Status, memory maps, file descriptors
- **Process control** — Debugging interfaces
- **Kernel information** — System-wide data

## Source Files

- `procfs_subr.c` — Support routines
- `procfs_vnops.c` — Vnode operations
- `procfs_vfsops.c` — VFS operations
- `procfs_status.c` — Process status
- `procfs_map.c` — Memory maps
- `procfs_mem.c` — Process memory access

## See Also

- [Processes](../kern/processes.md) — Process management
- [VFS Overview](index.md) — Filesystem implementations
