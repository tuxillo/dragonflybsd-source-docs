# SMB/CIFS Filesystem (smbfs)

smbfs provides client access to SMB/CIFS network shares.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/smbfs/` (~4,700 lines)

smbfs enables Windows file sharing access:

- **SMB protocol** — Windows file sharing
- **Authentication** — User/password authentication
- **Network shares** — Mount remote shares locally

## Source Files

- `smbfs_vnops.c` — Vnode operations
- `smbfs_vfsops.c` — VFS operations
- `smbfs_io.c` — I/O handling
- `smbfs_node.c` — Node management

## See Also

- [NFS](nfs.md) — Network File System
- [VFS Overview](index.md) — Filesystem implementations
