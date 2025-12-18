# Dead Filesystem (deadfs)

deadfs provides vnode operations for revoked or dead vnodes.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/deadfs/` (~210 lines)

deadfs is the simplest filesystem — it handles vnodes that have been revoked or are otherwise invalid:

- **Error returns** — All operations return appropriate errors
- **Revoked vnodes** — Used after `revoke(2)` system call
- **Cleanup** — Safe operations on dead file handles

## Source Files

- `dead_vnops.c` — Vnode operations (all fail gracefully)

## See Also

- [VFS Operations](../kern/vfs/vfs-operations.md) — Vnode operations
- [VFS Overview](index.md) — Filesystem implementations
