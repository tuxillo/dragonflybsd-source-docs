# NTFS Filesystem

ntfs provides read-only support for Windows NTFS filesystems.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/ntfs/` (~4,700 lines)

ntfs enables Windows NTFS access:

- **Read-only** — No write support
- **MFT-based** — Master File Table structure
- **Compression** — Basic compressed file support

## Source Files

- `ntfs_vnops.c` — Vnode operations
- `ntfs_vfsops.c` — VFS operations
- `ntfs_subr.c` — Support routines
- `ntfs_compr.c` — Compression handling

## See Also

- [msdosfs](msdosfs.md) — FAT filesystem (read/write)
- [VFS Overview](index.md) — Filesystem implementations
