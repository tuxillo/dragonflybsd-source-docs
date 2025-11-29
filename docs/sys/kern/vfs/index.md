# Virtual Filesystem (VFS)

*Documentation in progress. See planning/sys/kern/PLAN.md Phase 6 for details.*

## Overview

The Virtual Filesystem layer provides an abstraction between the kernel and concrete filesystem implementations.

## Key Components

- VFS core and vnode operations
- Name lookup and caching
- Buffer cache and I/O clustering
- Mount/unmount operations
- Journaling support

## Key Files (~23 files)

- `vfs_init.c`, `vfs_conf.c`, `vfs_subr.c`
- `vfs_vfsops.c`, `vfs_vnops.c`, `vfs_vopops.c`
- `vfs_cache.c`, `vfs_lookup.c`, `vfs_nlookup.c`
- `vfs_bio.c`, `vfs_cluster.c`
- And more...
