# ISO 9660 Filesystem (isofs)

isofs provides support for ISO 9660 CD-ROM/DVD filesystems.

## Overview

!!! note "Documentation Status"
    This page is a stub. Detailed documentation is planned.

**Source**: `sys/vfs/isofs/` (~4,600 lines)

isofs enables CD/DVD access:

- **ISO 9660** — Standard CD-ROM format
- **Rock Ridge** — Unix extensions (permissions, symlinks)
- **Joliet** — Unicode filename support

## Source Files

Files in `sys/vfs/isofs/cd9660/`:

- `cd9660_vnops.c` — Vnode operations
- `cd9660_vfsops.c` — VFS operations
- `cd9660_node.c` — ISO node handling
- `cd9660_rrip.c` — Rock Ridge extensions

## See Also

- [UDF](udf.md) — DVD/Blu-ray filesystem
- [VFS Overview](index.md) — Filesystem implementations
