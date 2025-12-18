# HAMMER Filesystem

HAMMER is DragonFly BSD's legacy native filesystem, predecessor to HAMMER2.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/hammer/` (~34,600 lines)

HAMMER was DragonFly's first native filesystem, featuring:

- **B-tree based** — Efficient on-disk organization
- **History retention** — Built-in historical snapshots
- **Mirroring** — Native filesystem mirroring
- **Large filesystem support** — Multi-terabyte volumes

## Key Features

| Feature | Description |
|---------|-------------|
| Design | B-tree based |
| History | Automatic retention with pruning |
| Mirroring | Streaming replication |
| Max size | Up to 1 exabyte (theoretical) |

## Source Files

Key source files in `sys/vfs/hammer/`:

- `hammer.h` — Main header
- `hammer_vfsops.c` — VFS operations
- `hammer_vnops.c` — Vnode operations
- `hammer_btree.c` — B-tree implementation
- `hammer_ondisk.c` — On-disk format
- `hammer_transaction.c` — Transaction handling
- `hammer_mirror.c` — Mirroring support
- `hammer_prune.c` — History pruning

## See Also

- [HAMMER2](hammer2.md) — Current native filesystem
- [VFS Overview](index.md) — Filesystem implementations
