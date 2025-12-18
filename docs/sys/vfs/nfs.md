# Network File System (NFS)

NFS provides network-transparent file access using Sun's NFS protocol.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/nfs/` (~24,700 lines)

NFS implements both client and server:

- **NFSv2/v3** — Standard NFS protocol versions
- **RPC-based** — Uses Sun RPC for communication
- **Caching** — Client-side caching with cache coherency
- **Locking** — NLM (Network Lock Manager) support

## Source Files

Key files in `sys/vfs/nfs/`:

- `nfs_vnops.c` — Client vnode operations
- `nfs_vfsops.c` — Client VFS operations
- `nfs_socket.c` — RPC/network handling
- `nfs_bio.c` — Client buffer I/O
- `nfs_serv.c` — Server operations
- `nfs_subs.c` — Support routines

## See Also

- [Sockets](../kern/ipc/sockets.md) — Network communication
- [VFS Overview](index.md) — Filesystem implementations
