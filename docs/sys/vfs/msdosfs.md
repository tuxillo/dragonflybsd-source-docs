# FAT Filesystem (msdosfs)

msdosfs provides support for FAT12, FAT16, and FAT32 filesystems.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/msdosfs/` (~8,100 lines)

msdosfs enables DOS/Windows FAT compatibility:

- **FAT12/16/32** — All FAT variants supported
- **Long filenames** — VFAT long filename support
- **USB drives** — Common for removable media

## Source Files

- `msdosfs_vnops.c` — Vnode operations
- `msdosfs_vfsops.c` — VFS operations
- `msdosfs_fat.c` — FAT table handling
- `msdosfs_denode.c` — Directory entry nodes
- `msdosfs_lookup.c` — Directory lookup

## See Also

- [VFS Overview](index.md) — Filesystem implementations
