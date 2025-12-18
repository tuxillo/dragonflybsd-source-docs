# Memory Filesystem (mfs)

mfs is a legacy memory-based filesystem using a block device interface.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/mfs/` (~700 lines)

mfs provides a memory-backed block device:

- **Legacy** — Older approach, tmpfs preferred for new uses
- **Block-based** — Presents as block device to UFS
- **Fixed size** — Allocated at mount time

## Source Files

- `mfs_vfsops.c` — VFS operations
- `mfs_vnops.c` — Vnode operations

## See Also

- [tmpfs](tmpfs.md) — Modern memory filesystem
- [VFS Overview](index.md) — Filesystem implementations
