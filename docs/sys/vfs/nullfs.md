# Null Filesystem (nullfs)

nullfs provides a loopback/stacking layer to mount directories elsewhere.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/nullfs/` (~770 lines)

nullfs allows mounting a directory tree at another location:

- **Loopback mount** — Expose directory at alternate path
- **Filesystem stacking** — Layers on top of underlying filesystem
- **Jail support** — Commonly used for jail filesystem setup

## Usage

```sh
mount_null /usr/src /jail/usr/src
```

## Source Files

- `null_vnops.c` — Vnode operations (pass-through)
- `null_vfsops.c` — VFS operations
- `null_subr.c` — Support routines

## See Also

- [Mounting](../kern/vfs/mounting.md) — Mount operations
- [VFS Overview](index.md) — Filesystem implementations
