# Universal Disk Format (UDF)

udf provides support for UDF filesystems used on DVDs and Blu-ray discs.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/udf/` (~3,000 lines)

udf enables DVD/Blu-ray access:

- **UDF standard** — OSTA Universal Disk Format
- **DVD/Blu-ray** — Optical media support
- **Read-only** — Primary use case

## Source Files

- `udf_vnops.c` — Vnode operations
- `udf_vfsops.c` — VFS operations
- `udf_subr.c` — Support routines

## See Also

- [isofs](isofs.md) — ISO 9660 CD-ROM filesystem
- [VFS Overview](index.md) — Filesystem implementations
