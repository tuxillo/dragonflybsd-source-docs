# HAMMER2 On-Disk Format

This document describes the on-disk media structures for HAMMER2, based on `sys/vfs/hammer2/hammer2_disk.h`.

## Overview

HAMMER2 is a copy-on-write filesystem where all data references use 64-bit byte offsets. The filesystem revolves around a hierarchical block reference structure, with everything referenced through 128-byte **blockrefs**. Key characteristics:

- **Block device buffers**: Always 64KB (`HAMMER2_PBUFSIZE`)
- **Logical file buffers**: Typically 16KB (`HAMMER2_LBUFSIZE`)
- **Minimum allocation**: 1KB (`HAMMER2_ALLOC_MIN`)
- **Maximum allocation**: 64KB (`HAMMER2_ALLOC_MAX`)
- **All fields**: Naturally aligned, host byte order

## Volume Layout

HAMMER2 media is organized into **2GB zones**. Each zone begins with a **4MB reserved segment** containing:

- Volume header (or backup)
- Freemap blocks (8 rotations × 5 levels)
- Reserved space for future use

```
Zone Layout (2GB each):
┌─────────────────────────────────────────────────────────────┐
│ 4MB Reserved Segment (64 × 64KB blocks)                     │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Block 0:     Volume Header (first 4 zones only)         │ │
│ │ Blocks 1-5:  Freemap Set 0 (levels 1-5)                 │ │
│ │ Blocks 6-10: Freemap Set 1                              │ │
│ │ Blocks 11-15: Freemap Set 2                             │ │
│ │ Blocks 16-20: Freemap Set 3                             │ │
│ │ Blocks 21-25: Freemap Set 4                             │ │
│ │ Blocks 26-30: Freemap Set 5                             │ │
│ │ Blocks 31-35: Freemap Set 6                             │ │
│ │ Blocks 36-40: Freemap Set 7                             │ │
│ │ Blocks 41-63: Reserved/Unused                           │ │
│ └─────────────────────────────────────────────────────────┘ │
│ ~2GB - 4MB: Allocatable Storage                             │
└─────────────────────────────────────────────────────────────┘
```

### Volume Headers

Up to **4 volume headers** exist at the start of the first four 2GB zones (offsets 0, 2GB, 4GB, 6GB). The filesystem rotates through these on each flush, providing crash recovery points.

**Source**: `hammer2_disk.h:1139-1141`
```c
#define HAMMER2_VOLUME_ID_HBO   0x48414d3205172011LLU  /* "HAM2" + date */
#define HAMMER2_VOLUME_ID_ABO   0x11201705324d4148LLU  /* byte-swapped */
```

## Volume Header Structure

The volume header is a 64KB block containing filesystem metadata:

**Source**: `hammer2_disk.h:1152-1276` (`struct hammer2_volume_data`)

```
Volume Header Layout (64KB):
┌────────────────────────────────────────────────────────────┐
│ Sector 0 (0x000-0x1FF): Core Metadata - 512 bytes          │
│   magic, boot/aux areas, volume size, version, flags       │
│   fsid, fstype, allocator info, mirror_tid, freemap_tid    │
│   icrc_sects[8] at end                                     │
├────────────────────────────────────────────────────────────┤
│ Sector 1 (0x200-0x3FF): Super-root Blockset - 512 bytes    │
│   4 × 128-byte blockrefs pointing to super-root            │
├────────────────────────────────────────────────────────────┤
│ Sector 2 (0x400-0x5FF): Reserved - 512 bytes               │
├────────────────────────────────────────────────────────────┤
│ Sector 3 (0x600-0x7FF): Reserved - 512 bytes               │
├────────────────────────────────────────────────────────────┤
│ Sector 4 (0x800-0x9FF): Freemap Blockset - 512 bytes       │
│   4 × 128-byte blockrefs for freemap root                  │
├────────────────────────────────────────────────────────────┤
│ Sector 5 (0xA00-0xBFF): Reserved - 512 bytes               │
├────────────────────────────────────────────────────────────┤
│ Sector 6 (0xC00-0xDFF): Reserved - 512 bytes               │
├────────────────────────────────────────────────────────────┤
│ Sector 7 (0xE00-0xFFF): Volume Offsets - 512 bytes         │
│   volu_loff[64] - offsets for multi-volume support         │
├────────────────────────────────────────────────────────────┤
│ Sectors 8-71 (0x1000-0x8FFF): Copy Info - 32KB             │
│   copyinfo[256] - cluster configuration                    │
├────────────────────────────────────────────────────────────┤
│ Reserved (0x9000-0xFFFB): Future Use - ~28KB               │
├────────────────────────────────────────────────────────────┤
│ Final 4 bytes (0xFFFC-0xFFFF): Volume Header CRC           │
└────────────────────────────────────────────────────────────┘
```

### Key Volume Header Fields

| Offset | Field | Description |
|--------|-------|-------------|
| 0x0000 | `magic` | Volume signature (`HAMMER2_VOLUME_ID_HBO`) |
| 0x0008 | `boot_beg/end` | Boot area boundaries |
| 0x0018 | `aux_beg/end` | Auxiliary area boundaries |
| 0x0028 | `volu_size` | Volume size in bytes |
| 0x0030 | `version` | Volume format version |
| 0x0034 | `flags` | Volume flags |
| 0x0038 | `copyid` | Copy ID of this physical volume |
| 0x0039 | `freemap_version` | Freemap algorithm version |
| 0x003B | `volu_id` | Volume ID (0-63) |
| 0x003C | `nvolumes` | Number of volumes |
| 0x0040 | `fsid` | Filesystem UUID |
| 0x0050 | `fstype` | Filesystem type UUID |
| 0x0060 | `allocator_size` | Total allocatable space |
| 0x0068 | `allocator_free` | Free space remaining |
| 0x0070 | `allocator_beg` | Start of dynamic allocations |
| 0x0078 | `mirror_tid` | Highest committed topology TID |
| 0x0090 | `freemap_tid` | Highest committed freemap TID |
| 0x0098 | `bulkfree_tid` | Bulkfree incremental TID |
| 0x00C0 | `total_size` | Total size across all volumes |
| 0x0200 | `sroot_blockset` | Super-root directory blockrefs |
| 0x0800 | `freemap_blockset` | Freemap root blockrefs |

## Block Reference (blockref)

The **blockref** is HAMMER2's fundamental building block — a 128-byte structure that references any block in the filesystem. Blockrefs appear in:

- Volume header (super-root and freemap)
- Inodes (embedded blockset)
- Indirect blocks (arrays of 512 blockrefs per 64KB)

**Source**: `hammer2_disk.h:619-697` (`struct hammer2_blockref`)

```c
struct hammer2_blockref {          /* MUST BE EXACTLY 128 BYTES */
    uint8_t     type;              /* 00: type of underlying item */
    uint8_t     methods;           /* 01: check method & compression method */
    uint8_t     copyid;            /* 02: specify which copy this is */
    uint8_t     keybits;           /* 03: #of keybits masked off 0=leaf */
    uint8_t     vradix;            /* 04: virtual data/meta-data size */
    uint8_t     flags;             /* 05: blockref flags */
    uint16_t    leaf_count;        /* 06-07: leaf aggregation count */
    hammer2_key_t   key;           /* 08-0F: key specification */
    hammer2_tid_t   mirror_tid;    /* 10-17: media flush tid */
    hammer2_tid_t   modify_tid;    /* 18-1F: clc modify (not propagated) */
    hammer2_off_t   data_off;      /* 20-27: physical offset + radix */
    hammer2_tid_t   update_tid;    /* 28-2F: clc update (propagated up) */
    union {                        /* 30-3F: embedded data (16 bytes) */
        char buf[16];
        hammer2_dirent_head_t dirent;  /* directory entry header */
        struct {
            hammer2_key_t data_count;
            hammer2_key_t inode_count;
        } stats;                   /* statistics for INODE/INDIRECT */
    } embed;
    union {                        /* 40-7F: check data (64 bytes) */
        char buf[64];
        struct { uint32_t value; } iscsi32;
        struct { uint64_t value; } xxhash64;
        struct { char data[24]; } sha192;
        struct { char data[32]; } sha256;
        struct { char data[64]; } sha512;
        struct {                   /* freemap hints */
            uint32_t icrc32;
            uint32_t bigmask;      /* available radixes */
            uint64_t avail;        /* available bytes */
        } freemap;
    } check;
};
```

### Blockref Type Field

**Source**: `hammer2_disk.h:711-720`

| Value | Name | Description |
|-------|------|-------------|
| 0 | `EMPTY` | Empty/unused slot |
| 1 | `INODE` | Inode block |
| 2 | `INDIRECT` | Indirect block |
| 3 | `DATA` | Data block |
| 4 | `DIRENT` | Directory entry (embedded in blockref) |
| 5 | `FREEMAP_NODE` | Freemap indirect node |
| 6 | `FREEMAP_LEAF` | Freemap leaf (bitmap) |
| 254 | `FREEMAP` | Pseudo-type for freemap root |
| 255 | `VOLUME` | Pseudo-type for volume header |

### Data Offset Encoding

The `data_off` field encodes both the physical block address and the block size:

**Source**: `hammer2_disk.h:458-461`
```c
#define HAMMER2_OFF_MASK        0xFFFFFFFFFFFFFFC0ULL  /* address bits */
#define HAMMER2_OFF_MASK_RADIX  0x000000000000003FULL  /* size radix (low 6 bits) */
```

- **Bits 63-6**: Physical byte offset (64-byte aligned)
- **Bits 5-0**: Size radix (actual size = `1 << radix`)

A radix of 0 with `data_off = 0` indicates no data associated with the blockref.

### Check Methods

**Source**: `hammer2_disk.h:729-736`

| Value | Name | Description |
|-------|------|-------------|
| 0 | `NONE` | No check code |
| 1 | `DISABLED` | Check code disabled |
| 2 | `ISCSI32` | 32-bit iSCSI CRC |
| 3 | `XXHASH64` | 64-bit xxHash (default) |
| 4 | `SHA192` | 192-bit SHA hash |
| 5 | `FREEMAP` | Freemap-specific check |

### Compression Methods

**Source**: `hammer2_disk.h:741-746`

| Value | Name | Description |
|-------|------|-------------|
| 0 | `NONE` | No compression |
| 1 | `AUTOZERO` | Auto-zero detection |
| 2 | `LZ4` | LZ4 compression (default) |
| 3 | `ZLIB` | ZLIB compression |

### Blockset Structure

A **blockset** is an array of 4 blockrefs, used in volume headers and inodes:

**Source**: `hammer2_disk.h:782-786`
```c
struct hammer2_blockset {
    hammer2_blockref_t  blockref[HAMMER2_SET_COUNT];  /* 4 entries */
};
```

This provides 4 × 128 = 512 bytes of block references.

## Inode Structure

Inodes are **1KB structures** containing metadata and either direct data or blockrefs:

**Source**: `hammer2_disk.h:1010-1020` (`struct hammer2_inode_data`)

```
Inode Layout (1024 bytes):
┌────────────────────────────────────────────────────────────┐
│ meta (0x000-0x0FF): Inode Metadata - 256 bytes             │
│   version, timestamps (ctime/mtime/atime/btime)            │
│   uid, gid, type, mode, size, inum, nlinks                 │
│   name_key, comp_algo, check_algo, PFS info                │
├────────────────────────────────────────────────────────────┤
│ filename (0x100-0x1FF): Filename - 256 bytes               │
│   Up to 256 characters, unterminated                       │
├────────────────────────────────────────────────────────────┤
│ u (0x200-0x3FF): Data/Blockset Union - 512 bytes           │
│   EITHER: blockset (4 × 128-byte blockrefs)                │
│   OR:     data[512] (direct embedded data for small files) │
└────────────────────────────────────────────────────────────┘
```

### Inode Metadata Fields

**Source**: `hammer2_disk.h:921-1006` (`struct hammer2_inode_meta`)

| Offset | Field | Description |
|--------|-------|-------------|
| 0x00 | `version` | Inode data version |
| 0x03 | `pfs_subtype` | PFS sub-type (snapshot, etc.) |
| 0x04 | `uflags` | User flags (chflags) |
| 0x08 | `rmajor/rminor` | Device node major/minor |
| 0x10 | `ctime` | Inode change time |
| 0x18 | `mtime` | Modification time |
| 0x20 | `atime` | Access time (unsupported) |
| 0x28 | `btime` | Birth time |
| 0x30 | `uid` | User ID (UUID) |
| 0x40 | `gid` | Group ID (UUID) |
| 0x50 | `type` | Object type |
| 0x51 | `op_flags` | Operational flags |
| 0x52 | `cap_flags` | Capability flags |
| 0x54 | `mode` | Unix permissions |
| 0x58 | `inum` | Inode number |
| 0x60 | `size` | File size |
| 0x68 | `nlinks` | Hard link count |
| 0x70 | `iparent` | Nominal parent inode |
| 0x78 | `name_key` | Filename hash key |
| 0x80 | `name_len` | Filename length |
| 0x82 | `ncopies` | Number of copies |
| 0x83 | `comp_algo` | Compression algorithm |
| 0x85 | `check_algo` | Check code algorithm |
| 0x86 | `pfs_nmasters` | PFS master count |
| 0x87 | `pfs_type` | PFS type |
| 0x88 | `pfs_inum` | PFS inode allocator |
| 0x90 | `pfs_clid` | PFS cluster UUID |
| 0xA0 | `pfs_fsid` | PFS unique UUID |
| 0xB0 | `data_quota` | Data quota in bytes |
| 0xC0 | `inode_quota` | Inode count quota |

### Object Types

**Source**: `hammer2_disk.h:1026-1035`

| Value | Name | Description |
|-------|------|-------------|
| 0 | `UNKNOWN` | Unknown type |
| 1 | `DIRECTORY` | Directory |
| 2 | `REGFILE` | Regular file |
| 4 | `FIFO` | FIFO |
| 5 | `CDEV` | Character device |
| 6 | `BDEV` | Block device |
| 7 | `SOFTLINK` | Symbolic link |
| 9 | `SOCKET` | Socket |
| 10 | `WHITEOUT` | Whiteout entry |

### Direct Data vs Blockrefs

Files ≤ 512 bytes store data directly in the inode's `u.data[512]` area. The `OPFLAG_DIRECTDATA` flag indicates this mode:

**Source**: `hammer2_disk.h:1022`
```c
#define HAMMER2_OPFLAG_DIRECTDATA   0x01
```

Larger files use the `u.blockset` containing 4 blockrefs, which can reference:
- Up to 4 data blocks directly (files ≤ 256KB with 64KB blocks)
- Indirect blocks for larger files

## Directory Entry Structure

Small directory entries (filename ≤ 64 bytes) are embedded directly in blockrefs:

**Source**: `hammer2_disk.h:549-555` (`struct hammer2_dirent_head`)

```c
struct hammer2_dirent_head {
    hammer2_tid_t   inum;       /* 00-07: inode number */
    uint16_t        namlen;     /* 08-09: name length */
    uint8_t         type;       /* 0A: OBJTYPE_* */
    uint8_t         unused0B;   /* 0B: unused */
    uint8_t         unused0C[4];/* 0C-0F: unused */
};
```

The 16-byte header fits in `blockref.embed.dirent`, and the filename (up to 64 bytes) fits in `blockref.check.buf[64]`. Longer filenames require a separate 1KB data block.

## Freemap Structure

The freemap tracks free space using a hierarchical bitmap structure:

### Freemap Hierarchy

**Source**: `hammer2_disk.h:335-341`

| Level | Radix | Coverage | Structure |
|-------|-------|----------|-----------|
| 0 | 22 | 4MB | Bitmap entries (256 × 16KB chunks) |
| 1 | 30 | 1GB | Leaf block (`hammer2_bmap_data[256]`) |
| 2 | 38 | 256GB | Indirect node (256 blockrefs) |
| 3 | 46 | 64TB | Indirect node (256 blockrefs) |
| 4 | 54 | 16PB | Indirect node (256 blockrefs) |
| 5 | 62 | 4EB | Indirect node (256 blockrefs) |
| 6 | 64 | 16EB | Volume header (4 blockrefs) |

### Freemap Leaf Structure (bmap_data)

**Source**: `hammer2_disk.h:871-885` (`struct hammer2_bmap_data`)

```c
struct hammer2_bmap_data {
    int32_t  linear;           /* 00-03: linear sub-granular offset */
    uint16_t class;            /* 04-05: clustering class */
    uint8_t  reserved06;       /* 06 */
    uint8_t  reserved07;       /* 07 */
    uint32_t reserved08;       /* 08-0B */
    uint32_t reserved0C;       /* 0C-0F */
    uint32_t reserved10;       /* 10-13 */
    uint32_t reserved14;       /* 14-17 */
    uint32_t reserved18;       /* 18-1B */
    uint32_t avail;            /* 1C-1F: available bytes */
    uint32_t reserved20[8];    /* 20-3F */
    hammer2_bitmap_t bitmapq[8]; /* 40-7F: 512 bits = 256 × 2-bit entries */
};
```

Each 128-byte `bmap_data` entry manages 4MB of storage:
- 8 × 64-bit bitmap words = 512 bits
- 2 bits per 16KB chunk = 256 chunks
- 256 × 16KB = 4MB

### Bitmap Encoding

**Source**: `hammer2_disk.h:836-843`

| Bits | State | Description |
|------|-------|-------------|
| 00 | Free | Block is unallocated |
| 01 | Reserved | (reserved for future use) |
| 10 | Possibly Free | Marked by first bulkfree pass |
| 11 | Allocated | Block is in use |

### Linear Allocator

The `linear` field enables sub-16KB allocations (down to 1KB) within an already-allocated 16KB chunk. This is tracked in-memory and may be lost on unmount, causing the entire 16KB to appear allocated until a bulkfree scan reclaims it.

## Key Constants

**Source**: `hammer2_disk.h:86-121`

| Constant | Value | Description |
|----------|-------|-------------|
| `HAMMER2_ALLOC_MIN` | 1024 | Minimum allocation (1KB) |
| `HAMMER2_ALLOC_MAX` | 65536 | Maximum allocation (64KB) |
| `HAMMER2_PBUFSIZE` | 65536 | Physical buffer size (64KB) |
| `HAMMER2_LBUFSIZE` | 16384 | Logical buffer size (16KB) |
| `HAMMER2_SEGSIZE` | 4MB | Freemap segment size |
| `HAMMER2_BLOCKREF_BYTES` | 128 | Blockref structure size |
| `HAMMER2_INODE_BYTES` | 1024 | Inode structure size |
| `HAMMER2_INODE_MAXNAME` | 256 | Maximum filename length |
| `HAMMER2_EMBEDDED_BYTES` | 512 | Embedded data/blockset size |
| `HAMMER2_SET_COUNT` | 4 | Blockrefs per blockset |
| `HAMMER2_IND_COUNT_MAX` | 512 | Max blockrefs per indirect block |
| `HAMMER2_NUM_VOLHDRS` | 4 | Number of volume headers |
| `HAMMER2_MAX_VOLUMES` | 64 | Maximum volumes in filesystem |
| `HAMMER2_ZONE_BYTES64` | 2GB | Zone size |
| `HAMMER2_ZONE_SEG` | 4MB | Reserved segment per zone |

## PFS Types

**Source**: `hammer2_disk.h:1063-1073`

| Value | Name | Description |
|-------|------|-------------|
| 0x00 | `NONE` | No PFS type |
| 0x01 | `CACHE` | Local cache |
| 0x03 | `SLAVE` | Cluster slave |
| 0x04 | `SOFT_SLAVE` | Soft slave (local reads) |
| 0x05 | `SOFT_MASTER` | Soft master (local writes) |
| 0x06 | `MASTER` | Cluster master |
| 0x08 | `SUPROOT` | Super-root |
| 0x09 | `DUMMY` | Dummy/placeholder |

## See Also

- [HAMMER2 Overview](index.md) — Architecture overview
- [Chain Layer](chain-layer.md) — In-memory representation
- [Freemap Management](freemap.md) — Runtime freemap operations
- [VFS Operations](../../kern/vfs/vfs-operations.md) — VFS framework
