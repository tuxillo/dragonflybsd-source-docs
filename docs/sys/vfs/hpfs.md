# OS/2 HPFS Filesystem

hpfs provides support for OS/2's High Performance File System.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/hpfs/` (~4,500 lines)

hpfs enables access to OS/2 HPFS volumes:

- **Legacy** — OS/2 compatibility
- **Read-only** — Limited write support
- **B+ tree** — Directory structure

## Source Files

- `hpfs_vnops.c` — Vnode operations
- `hpfs_vfsops.c` — VFS operations
- `hpfs_subr.c` — Support routines

## See Also

- [VFS Overview](index.md) — Filesystem implementations
