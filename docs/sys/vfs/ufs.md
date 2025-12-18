# Unix File System (UFS/FFS)

UFS is the traditional BSD Unix File System, also known as FFS (Fast File System).

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/ufs/` (~19,400 lines)

UFS/FFS is the classic BSD filesystem:

- **Mature** — Decades of development and stability
- **Soft updates** — Metadata consistency without journaling
- **Quotas** — User/group disk quotas
- **Snapshots** — Filesystem snapshots

## Source Files

Key files in `sys/vfs/ufs/`:

- `ufs_vnops.c` — Vnode operations
- `ufs_vfsops.c` — VFS operations (in ffs/)
- `ufs_inode.c` — Inode management
- `ufs_lookup.c` — Directory lookup
- `ufs_quota.c` — Quota support
- `ffs_*` — Fast File System specific code

## See Also

- [Buffer Cache](../kern/vfs/buffer-cache.md) — Block caching
- [VFS Overview](index.md) — Filesystem implementations
