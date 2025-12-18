# Automounter Filesystem (autofs)

autofs provides automatic, on-demand filesystem mounting.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/autofs/` (~1,800 lines)

autofs enables automatic mounting:

- **On-demand** — Mount when accessed
- **Timeout unmount** — Unmount after idle period
- **Daemon integration** — Works with automountd

## Source Files

- `autofs_vnops.c` — Vnode operations
- `autofs_vfsops.c` — VFS operations
- `autofs_ioctl.c` — Daemon communication

## See Also

- [Mounting](../kern/vfs/mounting.md) — Mount operations
- [VFS Overview](index.md) — Filesystem implementations
