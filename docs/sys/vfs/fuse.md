# Filesystem in Userspace (FUSE)

fuse enables userspace programs to implement filesystems.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/fuse/` (~5,500 lines)

fuse provides a kernel-userspace filesystem interface:

- **Userspace filesystems** — Implement FS in user programs
- **FUSE protocol** — Standard Linux FUSE compatibility
- **Flexibility** — Any storage backend possible

## Architecture

```
Application → VFS → FUSE kernel module → /dev/fuse → Userspace daemon
```

## Source Files

- `fuse_vnops.c` — Vnode operations
- `fuse_vfsops.c` — VFS operations
- `fuse_ipc.c` — Kernel-userspace communication
- `fuse_device.c` — `/dev/fuse` device

## See Also

- [VFS Overview](index.md) — Filesystem implementations
