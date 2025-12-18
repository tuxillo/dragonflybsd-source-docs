# `sys/vfs/` Reading and Documentation Plan

This plan organizes the DragonFly BSD filesystem implementations (`sys/vfs/`) into logical reading phases. The directory contains 23 filesystem implementations totaling approximately 189,000 lines of code.

## Overview of `sys/vfs/` filesystems

The filesystems can be grouped by purpose and complexity:

### DragonFly-native filesystems (highest priority)
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **hammer2** | ~40,800 | DragonFly's current native filesystem with clustering, dedup, compression |
| **hammer** | ~34,600 | DragonFly's legacy filesystem (predecessor to HAMMER2) |

### Pseudo/virtual filesystems
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **devfs** | ~6,400 | Device filesystem — dynamic `/dev` management |
| **procfs** | ~3,800 | Process filesystem — `/proc` interface |
| **tmpfs** | ~5,000 | Memory-based temporary filesystem |
| **nullfs** | ~770 | Null/loopback filesystem (mount elsewhere) |
| **deadfs** | ~210 | Dead vnode operations (revoked vnodes) |
| **fifofs** | ~750 | FIFO (named pipe) filesystem |
| **mfs** | ~700 | Memory filesystem (legacy) |

### Traditional Unix filesystems
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **ufs** | ~19,400 | BSD Unix File System (FFS/UFS) |
| **nfs** | ~24,700 | Network File System client |

### Compatibility filesystems (read-only or limited write)
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **ext2fs** | ~12,400 | Linux ext2/ext3 filesystem support |
| **msdosfs** | ~8,100 | FAT12/FAT16/FAT32 filesystem |
| **ntfs** | ~4,700 | Windows NTFS (read-only) |
| **isofs** | ~4,600 | ISO 9660 CD-ROM filesystem |
| **udf** | ~3,000 | Universal Disk Format (DVD/Blu-ray) |
| **hpfs** | ~4,500 | OS/2 High Performance File System |

### Network/distributed filesystems
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **smbfs** | ~4,700 | SMB/CIFS client filesystem |
| **fuse** | ~5,500 | Filesystem in Userspace framework |

### Specialized filesystems
| Filesystem | Lines | Description |
|------------|-------|-------------|
| **autofs** | ~1,800 | Automounter filesystem |
| **dirfs** | ~3,100 | Directory-based filesystem (vkernel) |

---

## Suggested reading phases

The filesystems are organized into phases based on complexity and importance to understanding DragonFly BSD.

### Phase 1: Simple pseudo-filesystems (foundation)
**Goal:** Understand basic VFS implementation patterns with minimal complexity.

**1a. deadfs** (~210 lines) — simplest possible filesystem
- `dead_vnops.c` — vnode operations that always fail
- Outcome: understand vnode operation structure

**1b. fifofs** (~750 lines) — named pipe support
- Understand FIFO vnode operations
- Outcome: see how special file types integrate with VFS

**1c. nullfs** (~770 lines) — loopback/stacking filesystem
- Understand filesystem layering/stacking
- Outcome: see how one filesystem can wrap another

**1d. mfs** (~700 lines) — memory filesystem (legacy)
- Simple memory-backed block device
- Outcome: understand block-based filesystem basics

---

### Phase 2: Memory and device filesystems
**Goal:** Understand dynamic filesystem construction.

**2a. tmpfs** (~5,000 lines) — modern memory filesystem
Files:
- `tmpfs_subr.c` — node management, memory allocation
- `tmpfs_vnops.c` — vnode operations
- `tmpfs_vfsops.c` — VFS operations (mount/unmount)
- `tmpfs_fifoops.c` — FIFO support within tmpfs

Outcome: understand a complete, modern pseudo-filesystem implementation.

**2b. devfs** (~6,400 lines) — device filesystem
Files:
- `devfs_core.c` — device node management
- `devfs_vnops.c` — vnode operations
- `devfs_vfsops.c` — VFS operations
- `devfs_rules.c` — permission/access rules

Outcome: understand dynamic device node creation and management.

**2c. procfs** (~3,800 lines) — process filesystem
Files:
- `procfs_subr.c` — proc node support
- `procfs_vnops.c` — vnode operations
- `procfs_vfsops.c` — VFS operations
- Various `procfs_*.c` — specific /proc entries

Outcome: understand how kernel data is exposed via filesystem interface.

---

### Phase 3: Traditional disk filesystems
**Goal:** Understand on-disk filesystem structures and operations.

**3a. ufs** (~19,400 lines) — BSD Unix File System
Key files:
- `ufs/ufs_vnops.c` — vnode operations
- `ufs/ufs_vfsops.c` — VFS operations
- `ufs/ufs_inode.c` — inode management
- `ufs/ufs_lookup.c` — directory lookup
- `ufs/ufs_quota.c` — quota support
- `ufs/ffs_*` — Fast File System specifics

Outcome: understand traditional Unix filesystem implementation.

**3b. ext2fs** (~12,400 lines) — Linux ext2/ext3
Key files:
- `ext2fs_vnops.c` — vnode operations
- `ext2fs_vfsops.c` — VFS operations
- `ext2fs_inode.c` — inode handling
- `ext2fs_lookup.c` — directory operations

Outcome: understand ext2 on-disk format and Linux compatibility.

---

### Phase 4: Network filesystems
**Goal:** Understand distributed filesystem protocols.

**4a. nfs** (~24,700 lines) — Network File System
Key files:
- `nfs_vnops.c` — vnode operations
- `nfs_vfsops.c` — VFS operations
- `nfs_socket.c` — RPC/network communication
- `nfs_subs.c` — NFS support routines
- `nfs_bio.c` — NFS buffer I/O
- `nfs_serv.c` — NFS server operations

Outcome: understand NFS protocol, RPC, caching strategies.

**4b. smbfs** (~4,700 lines) — SMB/CIFS client
Key files:
- `smbfs_vnops.c` — vnode operations
- `smbfs_vfsops.c` — VFS operations
- `smbfs_io.c` — I/O handling
- `smbfs_node.c` — node management

Outcome: understand SMB protocol integration.

---

### Phase 5: Userspace and automount filesystems
**Goal:** Understand filesystems that delegate to userspace.

**5a. fuse** (~5,500 lines) — Filesystem in Userspace
Key files:
- `fuse_vnops.c` — vnode operations
- `fuse_vfsops.c` — VFS operations
- `fuse_ipc.c` — kernel-userspace communication
- `fuse_device.c` — /dev/fuse device

Outcome: understand FUSE protocol and kernel-userspace boundary.

**5b. autofs** (~1,800 lines) — automounter
Key files:
- `autofs_vnops.c` — vnode operations
- `autofs_vfsops.c` — VFS operations
- `autofs_ioctl.c` — automount daemon interface

Outcome: understand on-demand mounting.

---

### Phase 6: Media filesystems
**Goal:** Understand read-only and media-specific filesystems.

**6a. isofs** (~4,600 lines) — ISO 9660
Key files:
- `cd9660_vnops.c` — vnode operations
- `cd9660_vfsops.c` — VFS operations
- `cd9660_node.c` — ISO node handling
- `cd9660_rrip.c` — Rock Ridge extensions

Outcome: understand CD/DVD filesystem format.

**6b. msdosfs** (~8,100 lines) — FAT filesystem
Key files:
- `msdosfs_vnops.c` — vnode operations
- `msdosfs_vfsops.c` — VFS operations
- `msdosfs_fat.c` — FAT table handling
- `msdosfs_denode.c` — directory entry nodes

Outcome: understand FAT12/16/32 format.

**6c. udf** (~3,000 lines) — Universal Disk Format
Key files:
- `udf_vnops.c` — vnode operations
- `udf_vfsops.c` — VFS operations

Outcome: understand DVD/Blu-ray filesystem.

**6d. ntfs** (~4,700 lines) — NTFS (read-only)
Key files:
- `ntfs_vnops.c` — vnode operations
- `ntfs_vfsops.c` — VFS operations
- `ntfs_subr.c` — NTFS support routines

Outcome: understand NTFS MFT structure.

---

### Phase 7: HAMMER (legacy native filesystem)
**Goal:** Understand DragonFly's first native filesystem.

**hammer** (~34,600 lines) — HAMMER filesystem
Key files (read in order):
1. `hammer.h` — main header, structures
2. `hammer_ondisk.c` — on-disk format
3. `hammer_btree.c` — B-tree implementation
4. `hammer_object.c` — object management
5. `hammer_vnops.c` — vnode operations
6. `hammer_vfsops.c` — VFS operations
7. `hammer_transaction.c` — transaction handling
8. `hammer_undo.c` — undo/redo logging
9. `hammer_mirror.c` — mirroring support
10. `hammer_reblock.c` — reblocking/defrag
11. `hammer_prune.c` — history pruning

Outcome: comprehensive understanding of HAMMER design and implementation.

---

### Phase 8: HAMMER2 (current native filesystem)
**Goal:** Master DragonFly's primary filesystem.

**hammer2** (~40,800 lines) — HAMMER2 filesystem
Key files (read in order):
1. `hammer2.h` — main header, core structures
2. `hammer2_ondisk.c` — on-disk format
3. `hammer2_chain.c` — chain/topology management
4. `hammer2_cluster.c` — clustering support
5. `hammer2_inode.c` — inode operations
6. `hammer2_vnops.c` — vnode operations
7. `hammer2_vfsops.c` — VFS operations
8. `hammer2_freemap.c` — free space management
9. `hammer2_flush.c` — flush/sync operations
10. `hammer2_strategy.c` — I/O strategy
11. `hammer2_io.c` — I/O subsystem
12. `hammer2_lz4.c`, `hammer2_zlib.c` — compression
13. `hammer2_xops.c` — extended operations
14. `hammer2_synchro.c` — synchronization
15. `hammer2_bulkfree.c` — bulk free operations

Outcome: expert-level understanding of HAMMER2 architecture.

---

### Phase 9: Specialized filesystems (optional)
**Goal:** Document remaining specialized filesystems.

**9a. hpfs** (~4,500 lines) — OS/2 filesystem
- Legacy, low priority

**9b. dirfs** (~3,100 lines) — vkernel directory filesystem
- Specialized for virtual kernel use

---

## Documentation structure

For each filesystem, create documentation under `docs/sys/vfs/<filesystem>/`:

```
docs/sys/vfs/
├── index.md              # VFS filesystem overview
├── hammer2/
│   ├── index.md          # HAMMER2 overview
│   ├── architecture.md   # Design and architecture
│   ├── on-disk.md        # On-disk format
│   ├── chains.md         # Chain topology
│   └── operations.md     # Key operations
├── hammer/
│   ├── index.md          # HAMMER overview
│   └── ...
├── tmpfs.md              # Simple filesystems get single file
├── devfs.md
├── procfs.md
├── nullfs.md
├── ...
```

---

## Progress tracking

| Phase | Subsystem | Status | Notes |
|-------|-----------|--------|-------|
| 1a | deadfs | [ ] Not started | |
| 1b | fifofs | [ ] Not started | |
| 1c | nullfs | [ ] Not started | |
| 1d | mfs | [ ] Not started | |
| 2a | tmpfs | [ ] Not started | |
| 2b | devfs | [ ] Not started | |
| 2c | procfs | [ ] Not started | |
| 3a | ufs | [ ] Not started | |
| 3b | ext2fs | [ ] Not started | |
| 4a | nfs | [ ] Not started | |
| 4b | smbfs | [ ] Not started | |
| 5a | fuse | [ ] Not started | |
| 5b | autofs | [ ] Not started | |
| 6a | isofs | [ ] Not started | |
| 6b | msdosfs | [ ] Not started | |
| 6c | udf | [ ] Not started | |
| 6d | ntfs | [ ] Not started | |
| 7 | hammer | [ ] Not started | |
| 8 | hammer2 | [ ] Not started | |
| 9a | hpfs | [ ] Not started | Optional |
| 9b | dirfs | [ ] Not started | Optional |

---

## Key concepts to document across all filesystems

1. **VFS integration** — How each filesystem implements VFS operations
2. **On-disk format** — Disk layout, metadata structures (for disk-based FS)
3. **Locking strategy** — How concurrency is handled
4. **Caching** — Buffer cache usage, read-ahead strategies
5. **Error handling** — Recovery, consistency checking
6. **DragonFly-specific features** — LWKT integration, token usage

## Dependencies

Before starting VFS documentation, ensure familiarity with:
- `sys/kern/` VFS layer documentation (already complete)
- VM subsystem documentation (already complete)
- LWKT threading model
