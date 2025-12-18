# Device Filesystem (devfs)

devfs provides dynamic device node management for `/dev`.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/devfs/` (~6,400 lines)

devfs dynamically creates and manages device nodes:

- **Dynamic creation** — Nodes created/removed as devices attach/detach
- **Rules system** — Configurable permissions and ownership
- **Per-jail support** — Isolated device namespaces

## Source Files

- `devfs_core.c` — Core device node management
- `devfs_vnops.c` — Vnode operations
- `devfs_vfsops.c` — VFS operations
- `devfs_rules.c` — Permission rules

## See Also

- [Devices](../kern/devices.md) — Device framework
- [VFS Overview](index.md) — Filesystem implementations
