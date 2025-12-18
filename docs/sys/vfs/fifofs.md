# FIFO Filesystem (fifofs)

fifofs implements named pipes (FIFOs) as a filesystem layer.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/fifofs/` (~750 lines)

fifofs provides:

- **Named pipes** — FIFO special files
- **VFS integration** — FIFOs as vnode type
- **Blocking I/O** — Reader/writer synchronization

## Source Files

- `fifo_vnops.c` — Vnode operations for FIFOs

## See Also

- [Pipes](../kern/ipc/pipes.md) — Pipe implementation
- [VFS Overview](index.md) — Filesystem implementations
