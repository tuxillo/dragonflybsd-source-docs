# Linux ext2/ext3 Filesystem (ext2fs)

ext2fs provides read/write support for Linux ext2 and ext3 filesystems.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/ext2fs/` (~12,400 lines)

ext2fs enables Linux filesystem compatibility:

- **ext2 support** — Full read/write
- **ext3 support** — Read/write (journal ignored)
- **Linux compatibility** — Access Linux partitions

## Source Files

- `ext2fs_vnops.c` — Vnode operations
- `ext2fs_vfsops.c` — VFS operations
- `ext2fs_inode.c` — Inode handling
- `ext2fs_lookup.c` — Directory operations
- `ext2fs_balloc.c` — Block allocation

## See Also

- [UFS](ufs.md) — Native BSD filesystem
- [VFS Overview](index.md) — Filesystem implementations
