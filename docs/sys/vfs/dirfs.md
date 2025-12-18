# Directory Filesystem (dirfs)

dirfs provides pass-through filesystem access for the virtual kernel (vkernel).

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/dirfs/` (~3,100 lines)

dirfs enables vkernel filesystem access:

- **Vkernel support** — Used by DragonFly's virtual kernel
- **Host passthrough** — Access host filesystem from vkernel
- **Development** — Useful for kernel development/testing

## Source Files

- `dirfs_vnops.c` — Vnode operations
- `dirfs_vfsops.c` — VFS operations
- `dirfs_subr.c` — Support routines

## See Also

- [VFS Overview](index.md) — Filesystem implementations
