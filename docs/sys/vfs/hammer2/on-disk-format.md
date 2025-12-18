# HAMMER2 On-Disk Format

!!! note "Documentation Status"
    This page documents the on-disk format of HAMMER2 based on `hammer2_disk.h`.

## Overview

HAMMER2 uses a hierarchical block reference structure where everything is referenced through 128-byte block references (blockrefs). The filesystem is copy-on-write, meaning data is never modified in place.

## Volume Layout

*Documentation in progress — will cover volume header structure and layout.*

## Block References

*Documentation in progress — will cover the 128-byte blockref structure.*

## Inodes

*Documentation in progress — will cover the 1KB inode structure.*

## Freemap

*Documentation in progress — will cover freemap on-disk layout.*

## See Also

- [HAMMER2 Overview](index.md)
- [Chain Layer](chain-layer.md) — In-memory representation
- [Freemap Management](freemap.md) — Runtime freemap operations
