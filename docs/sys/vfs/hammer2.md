# HAMMER2 Filesystem

HAMMER2 is DragonFly BSD's current native filesystem, designed for modern storage with advanced features.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/hammer2/` (~40,800 lines)

HAMMER2 is a high-performance, modern filesystem featuring:

- **Copy-on-write** — All modifications create new blocks
- **Built-in compression** — LZ4 and zlib support
- **Deduplication** — Block-level dedup
- **Snapshots** — Instant, space-efficient snapshots
- **Clustering** — Multi-master clustering support
- **Checksumming** — Data integrity verification

## Key Features

| Feature | Description |
|---------|-------------|
| Block size | Variable, up to 64KB |
| Compression | LZ4 (fast), zlib (better ratio) |
| Checksums | Per-block integrity checks |
| Snapshots | Copy-on-write based |
| Clustering | Planned multi-node support |

## Source Files

Key source files in `sys/vfs/hammer2/`:

- `hammer2.h` — Main header and structures
- `hammer2_vfsops.c` — VFS operations
- `hammer2_vnops.c` — Vnode operations
- `hammer2_chain.c` — Chain topology management
- `hammer2_inode.c` — Inode operations
- `hammer2_freemap.c` — Free space management
- `hammer2_io.c` — I/O subsystem
- `hammer2_flush.c` — Flush/sync operations
- `hammer2_lz4.c` — LZ4 compression
- `hammer2_zlib.c` — Zlib compression

## See Also

- [HAMMER](hammer.md) — Legacy HAMMER filesystem
- [VFS Overview](index.md) — Filesystem implementations
- [VFS Core](../kern/vfs/index.md) — VFS layer
