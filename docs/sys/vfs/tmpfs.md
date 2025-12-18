# Temporary Filesystem (tmpfs)

tmpfs is a memory-based filesystem for temporary storage.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/tmpfs/` (~5,000 lines)

tmpfs provides fast, memory-backed storage:

- **RAM-based** — All data stored in memory
- **Swap support** — Can page to swap under memory pressure
- **Full POSIX** — Complete filesystem semantics

## Source Files

- `tmpfs_subr.c` — Node management
- `tmpfs_vnops.c` — Vnode operations
- `tmpfs_vfsops.c` — VFS operations
- `tmpfs_fifoops.c` — FIFO support

## See Also

- [Memory](../kern/memory.md) — Memory management
- [VFS Overview](index.md) — Filesystem implementations
