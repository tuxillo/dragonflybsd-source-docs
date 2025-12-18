# Filesystem Implementations (`sys/vfs/`)

This section documents the filesystem implementations in DragonFly BSD. The `sys/vfs/` directory contains 23 filesystems totaling approximately 189,000 lines of code.

## Overview

DragonFly BSD supports a variety of filesystems for different purposes:

- **Native filesystems** — HAMMER2 (current) and HAMMER (legacy), developed specifically for DragonFly
- **Pseudo-filesystems** — Virtual filesystems like devfs, procfs, and tmpfs
- **Traditional Unix** — UFS/FFS and NFS for compatibility
- **Compatibility** — Support for ext2, FAT, NTFS, ISO9660, and others

All filesystems integrate with the kernel through the VFS (Virtual File System) layer documented in [VFS Core](../kern/vfs/index.md).

## Filesystem Summary

### DragonFly-Native Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [HAMMER2](hammer2.md) | ~40,800 | Current native filesystem with clustering, dedup, compression |
| [HAMMER](hammer.md) | ~34,600 | Legacy native filesystem |

### Pseudo/Virtual Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [devfs](devfs.md) | ~6,400 | Device filesystem — dynamic `/dev` management |
| [procfs](procfs.md) | ~3,800 | Process filesystem — `/proc` interface |
| [tmpfs](tmpfs.md) | ~5,000 | Memory-based temporary filesystem |
| [nullfs](nullfs.md) | ~770 | Null/loopback filesystem |
| [fifofs](fifofs.md) | ~750 | FIFO (named pipe) filesystem |
| [deadfs](deadfs.md) | ~210 | Dead vnode operations |
| [mfs](mfs.md) | ~700 | Memory filesystem (legacy) |

### Traditional Unix Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [UFS](ufs.md) | ~19,400 | BSD Unix File System (FFS) |
| [NFS](nfs.md) | ~24,700 | Network File System client/server |

### Compatibility Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [ext2fs](ext2fs.md) | ~12,400 | Linux ext2/ext3 support |
| [msdosfs](msdosfs.md) | ~8,100 | FAT12/FAT16/FAT32 |
| [ntfs](ntfs.md) | ~4,700 | Windows NTFS (read-only) |
| [isofs](isofs.md) | ~4,600 | ISO 9660 CD-ROM |
| [udf](udf.md) | ~3,000 | Universal Disk Format |
| [hpfs](hpfs.md) | ~4,500 | OS/2 HPFS |

### Network/Distributed Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [smbfs](smbfs.md) | ~4,700 | SMB/CIFS client |
| [fuse](fuse.md) | ~5,500 | Filesystem in Userspace |

### Specialized Filesystems

| Filesystem | Lines | Description |
|------------|-------|-------------|
| [autofs](autofs.md) | ~1,800 | Automounter filesystem |
| [dirfs](dirfs.md) | ~3,100 | Directory filesystem (vkernel) |

## Source Location

- **Source path**: `sys/vfs/`
- **Each filesystem**: `sys/vfs/<name>/`

## See Also

- [VFS Core](../kern/vfs/index.md) — VFS layer implementation
- [Buffer Cache](../kern/vfs/buffer-cache.md) — Block I/O caching
- [Mounting](../kern/vfs/mounting.md) — Mount operations
