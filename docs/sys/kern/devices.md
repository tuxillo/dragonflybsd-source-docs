# Device Framework

The device framework provides the infrastructure for creating, managing, and
operating on character and block devices in DragonFly BSD. It consists of
two main components: device number management (`kern_conf.c`) and device
operations dispatch (`kern_device.c`).

**Source files:**
- `sys/kern/kern_conf.c` - Device creation, destruction, aliases
- `sys/kern/kern_device.c` - Device operations dispatch layer
- `sys/sys/device.h` - Data structures and prototypes
- `sys/sys/conf.h` - Device type definitions

## Overview

DragonFly's device framework evolved from traditional BSD but incorporates
several DragonFly-specific enhancements:

1. **DEVFS Integration** - All device creation goes through devfs
2. **MPSAFE Support** - Per-device MPSAFE flags control locking
3. **KVABIO Support** - Efficient buffer handling for capable devices
4. **Reference Counting** - Sysref-based lifecycle management
5. **Operation Interception** - Console and layered device support

## Data Structures

### struct dev_ops

The device operations switch table. Each device driver provides one of these
to define how the device responds to operations.

```c
struct dev_ops {
    struct {
        const char  *name;   /* base name, e.g. 'da' */
        int          maj;    /* major device number */
        u_int        flags;  /* D_XXX flags */
        void        *data;   /* custom driver data */
        int          refs;   /* ref count */
        int          id;
    } head;

    d_default_t     *d_default;
    d_open_t        *d_open;
    d_close_t       *d_close;
    d_read_t        *d_read;
    d_write_t       *d_write;
    d_ioctl_t       *d_ioctl;
    d_mmap_t        *d_mmap;
    d_mmap_single_t *d_mmap_single;
    d_strategy_t    *d_strategy;
    d_dump_t        *d_dump;
    d_psize_t       *d_psize;
    d_kqfilter_t    *d_kqfilter;
    d_clone_t       *d_clone;
    d_revoke_t      *d_revoke;
    int (*d_uksmap)(...);
};
```

Defined in `sys/sys/device.h:229-257`.

### Device Flags (head.flags)

**Type flags** (mutually exclusive):

| Flag | Value | Description |
|------|-------|-------------|
| `D_TAPE` | 0x0001 | Tape device |
| `D_DISK` | 0x0002 | Disk device |
| `D_TTY` | 0x0004 | Terminal device |
| `D_MEM` | 0x0008 | Memory device |

**Behavior flags:**

| Flag | Value | Description |
|------|-------|-------------|
| `D_MEMDISK` | 0x00010000 | Memory-type disk |
| `D_CANFREE` | 0x00040000 | Supports TRIM/free blocks |
| `D_TRACKCLOSE` | 0x00080000 | Track all close calls |
| `D_MASTER` | 0x00100000 | Used by pty/tty code |
| `D_NOEMERGPGR` | 0x00200000 | Skip in emergency pager |
| `D_MPSAFE` | 0x00400000 | All operations are MPSAFE |
| `D_KVABIO` | 0x00800000 | Supports KVABIO API |
| `D_QUICK` | 0x01000000 | No fancy open/close needed |

Defined in `sys/sys/device.h:263-287`.

### cdev_t

Opaque pointer to a device structure. The actual structure (`struct cdev`)
is managed by devfs and contains:

- `si_ops` - Pointer to `struct dev_ops`
- `si_umajor`, `si_uminor` - Major/minor numbers
- `si_name` - Device name
- `si_uid`, `si_gid`, `si_perms` - Ownership and permissions
- `si_sysref` - Reference count
- `si_track_read`, `si_track_write` - BIO tracking
- `si_lastread`, `si_lastwrite` - Access timestamps

### Operation Argument Structures

Each device operation receives a typed argument structure derived from
`struct dev_generic_args`:

```c
struct dev_generic_args {
    struct syslink_desc *a_desc;  /* operation descriptor */
    struct cdev *a_dev;           /* device pointer */
};
```

**Common argument structures:**

| Structure | Operation | Key Fields |
|-----------|-----------|------------|
| `dev_open_args` | `d_open` | `a_oflags`, `a_devtype`, `a_cred`, `a_fpp` |
| `dev_close_args` | `d_close` | `a_fflag`, `a_devtype`, `a_fp` |
| `dev_read_args` | `d_read` | `a_uio`, `a_ioflag`, `a_fp` |
| `dev_write_args` | `d_write` | `a_uio`, `a_ioflag`, `a_fp` |
| `dev_ioctl_args` | `d_ioctl` | `a_cmd`, `a_data`, `a_fflag`, `a_cred` |
| `dev_strategy_args` | `d_strategy` | `a_bio` |
| `dev_mmap_args` | `d_mmap` | `a_offset`, `a_nprot`, `a_result` |
| `dev_dump_args` | `d_dump` | `a_virtual`, `a_physical`, `a_offset`, `a_length` |
| `dev_psize_args` | `d_psize` | `a_result` |

Defined in `sys/sys/device.h:59-204`.

## Device Creation

### make_dev

Creates a device node visible in `/dev`:

```c
cdev_t make_dev(struct dev_ops *ops, int minor,
                uid_t uid, gid_t gid, int perms,
                const char *fmt, ...);
```

**Operation:**
1. Call `compile_dev_ops()` to fill in NULL handlers
2. Create device via `devfs_new_cdev()`
3. Format device name from `fmt` and varargs
4. Create devfs entry via `devfs_create_dev()`
5. Return unreferenced device pointer

The returned `cdev_t` is an ad-hoc reference. Callers who store it
long-term must call `reference_dev()`.

See `sys/kern/kern_conf.c:188-211`.

### make_dev_covering

Creates a device that layers over another device:

```c
cdev_t make_dev_covering(struct dev_ops *ops, struct dev_ops *bops,
                         int minor, uid_t uid, gid_t gid, int perms,
                         const char *fmt, ...);
```

Used by disk label code to create partition devices that cover the
base disk device.

See `sys/kern/kern_conf.c:218-241`.

### make_only_dev

Creates a device without a devfs entry (internal use):

```c
cdev_t make_only_dev(struct dev_ops *ops, int minor,
                     uid_t uid, gid_t gid, int perms,
                     const char *fmt, ...);
```

Unlike `make_dev()`, this returns a referenced device.

See `sys/kern/kern_conf.c:270-296`.

### make_autoclone_dev

Creates an auto-cloning device:

```c
cdev_t make_autoclone_dev(struct dev_ops *ops, struct devfs_bitmap *bitmap,
                          d_clone_t *nhandler, uid_t uid, gid_t gid,
                          int perms, const char *fmt, ...);
```

**Operation:**
1. Initialize clone bitmap (if provided)
2. Register clone handler with devfs
3. Create base device covering `default_dev_ops`
4. Clone handler called on-demand for new instances

Used for devices like `/dev/pty*` that create instances dynamically.

See `sys/kern/kern_conf.c:407-427`.

## Device Destruction

### destroy_dev

Destroys a device and revectors its ops to `dead_dev_ops`:

```c
void destroy_dev(cdev_t dev);
```

**Important:** The caller must hold a reference to the device. The ad-hoc
reference from `make_dev()` is not sufficient:

```c
/* Wrong: */
destroy_dev(make_dev(...));

/* Correct: */
cdev_t dev = make_dev(...);
reference_dev(dev);
/* ... use device ... */
destroy_dev(dev);  /* releases caller's reference + ad-hoc reference */
```

See `sys/kern/kern_conf.c:345-354`.

### sync_devs

Synchronizes asynchronous disk and devfs operations:

```c
void sync_devs(void);
```

Called before mountroot and on module unload to ensure all devices
are fully probed and ops structures dereferenced.

See `sys/kern/kern_conf.c:364-371`.

## Device Aliases

### make_dev_alias

Creates a symbolic alias for an existing device:

```c
int make_dev_alias(cdev_t target, const char *fmt, ...);
```

See `sys/kern/kern_conf.c:373-387`.

### destroy_dev_alias

Removes a device alias:

```c
int destroy_dev_alias(cdev_t target, const char *fmt, ...);
```

See `sys/kern/kern_conf.c:389-403`.

## Reference Counting

Devices use sysref-based reference counting:

### reference_dev

Adds a reference to a device:

```c
cdev_t reference_dev(cdev_t dev);
```

Returns the device pointer for convenience. Callers storing device
pointers long-term should call this to prevent premature destruction.

See `sys/kern/kern_conf.c:453-467`.

### release_dev

Releases a device reference:

```c
void release_dev(cdev_t dev);
```

The device is freed when the last reference is released.

See `sys/kern/kern_conf.c:476-484`.

## Device Operations Dispatch

The `dev_d*()` functions in `kern_device.c` dispatch operations to
drivers while handling MPSAFE and KVABIO requirements.

### MPSAFE Handling

Each dispatch function checks the `D_MPSAFE` flag:

```c
static __inline int
dev_needmplock(cdev_t dev)
{
    return ((dev->si_ops->head.flags & D_MPSAFE) == 0);
}
```

If the device is not MPSAFE, the dispatch function acquires/releases
the big kernel lock:

```c
if (needmplock)
    get_mplock();
error = dev->si_ops->d_open(&ap);
if (needmplock)
    rel_mplock();
```

See `sys/kern/kern_device.c:117-122`.

### KVABIO Handling

For strategy operations, if the device doesn't support KVABIO but
the buffer uses it, data is synchronized to all CPUs:

```c
if (dev_nokvabio(dev) && (bp->b_flags & B_KVABIO))
    bkvasync_all(bp);
```

See `sys/kern/kern_device.c:366-367`.

### dev_dopen

Opens a device:

```c
int dev_dopen(cdev_t dev, int oflags, int devtype,
              struct ucred *cred, struct file **fpp, struct vnode *vp);
```

The `fpp` parameter allows the driver to replace the file pointer
during open (used by some devices for per-open state).

See `sys/kern/kern_device.c:137-168`.

### dev_dstrategy

Issues I/O to a device:

```c
void dev_dstrategy(cdev_t dev, struct bio *bio);
```

**Operation:**
1. Handle KVABIO synchronization if needed
2. Select read or write tracking based on `bio->bio_buf->b_cmd`
3. Reference the appropriate `bio_track`
4. Call `dsched_buf_enter()` for disk scheduling
5. Dispatch to driver's `d_strategy`

The BIO tracking allows `sync_devs()` to wait for outstanding I/O.

See `sys/kern/kern_device.c:354-389`.

### dev_dstrategy_chain

Chained strategy call (reuses existing BIO setup):

```c
void dev_dstrategy_chain(cdev_t dev, struct bio *bio);
```

Used when forwarding I/O through device layers. Unlike `dev_dstrategy()`,
it doesn't add new tracking.

See `sys/kern/kern_device.c:391-416`.

### dev_dpsize

Gets device/partition size:

```c
int64_t dev_dpsize(cdev_t dev);
```

Returns the size in device blocks, or -1 on error.

See `sys/kern/kern_device.c:448-467`.

## Operation Compilation

### compile_dev_ops

Fills in NULL operation pointers with defaults:

```c
void compile_dev_ops(struct dev_ops *ops);
```

For each NULL function pointer:
- If `d_default` is set, use that
- Otherwise, use the corresponding function from `default_dev_ops`

Called automatically by `make_dev()` and related functions.

See `sys/kern/kern_device.c:588-606`.

### default_dev_ops

Default operations that return `ENODEV` for most calls:

```c
struct dev_ops default_dev_ops = {
    { "null" },
    .d_default = NULL,
    .d_open = noopen,      /* returns ENODEV */
    .d_close = noclose,    /* returns ENODEV */
    .d_read = noread,      /* returns ENODEV */
    ...
};
```

See `sys/kern/kern_device.c:99-115`.

### dead_dev_ops

Operations for destroyed devices. When a device is destroyed, its
`si_ops` is revectored to point here.

See `sys/kern/kern_device.c:83`.

## Operation Interception

### dev_ops_intercept

Intercepts device operations (used by console code):

```c
struct dev_ops *dev_ops_intercept(cdev_t dev, struct dev_ops *iops);
```

**Operation:**
1. Save original ops
2. Copy major, data, and flags to interceptor ops
3. Replace device's ops with interceptor
4. Set `SI_INTERCEPTED` flag
5. Return original ops

See `sys/kern/kern_device.c:654-667`.

### dev_ops_restore

Restores original operations after interception:

```c
void dev_ops_restore(cdev_t dev, struct dev_ops *oops);
```

See `sys/kern/kern_device.c:669-679`.

## Major Number Management

Major numbers are tracked in a red-black tree for efficient lookup:

```c
struct dev_ops_rb_tree dev_ops_rbhead;
```

The tree maps major numbers to `struct dev_ops_maj` entries, which
link to the associated `dev_ops` structures.

See `sys/kern/kern_device.c:638-640`.

## Device Number Primitives

### major / minor

Extract major/minor numbers from a device:

```c
int major(cdev_t dev);
int minor(cdev_t dev);
```

Note: Major number comes from `si_umajor`, not `si_ops`, because
`si_ops` may be replaced when a device is destroyed.

See `sys/kern/kern_conf.c:61-75`.

### devid_from_dev / dev_from_devid

Convert between `cdev_t` and old-style `dev_t`:

```c
dev_t devid_from_dev(cdev_t dev);
cdev_t dev_from_devid(dev_t x, int b);
```

The `dev_from_devid()` function looks up the device through devfs.

See `sys/kern/kern_conf.c:99-124`.

### dev_is_good

Check if a device is valid (not dead):

```c
int dev_is_good(cdev_t dev);
```

Returns 1 if the device exists and its ops is not `dead_dev_ops`.

See `sys/kern/kern_conf.c:126-132`.

## Helper Functions

### devtoname

Gets the device name:

```c
const char *devtoname(cdev_t dev);
```

Returns the device name, or constructs one from major/minor if
no name is set.

See `sys/kern/kern_conf.c:486-512`.

### dev_dname / dev_dflags / dev_dmaj

Quick accessors for device properties:

```c
const char *dev_dname(cdev_t dev);   /* ops->head.name */
int dev_dflags(cdev_t dev);          /* ops->head.flags */
int dev_dmaj(cdev_t dev);            /* ops->head.maj */
```

See `sys/kern/kern_device.c:515-537`.

### dev_drefs

Gets the reference count:

```c
int dev_drefs(cdev_t dev);
```

See `sys/kern/kern_device.c:506-510`.

## Debugging

### debug.dev_refs

Sysctl to enable device reference debugging:

```
sysctl debug.dev_refs=2
```

When set to 2, prints reference/release messages with device name
and reference count.

See `sys/kern/kern_conf.c:52-54`.

## Example: Simple Character Device

```c
static d_open_t     mydev_open;
static d_close_t    mydev_close;
static d_read_t     mydev_read;
static d_write_t    mydev_write;

static struct dev_ops mydev_ops = {
    { "mydev", 0, D_MPSAFE },
    .d_open =   mydev_open,
    .d_close =  mydev_close,
    .d_read =   mydev_read,
    .d_write =  mydev_write,
};

static int
mydev_open(struct dev_open_args *ap)
{
    /* ap->a_head.a_dev is the device */
    /* ap->a_oflags has open flags */
    /* ap->a_cred has credentials */
    return 0;
}

static int
mydev_read(struct dev_read_args *ap)
{
    return uiomove(data, len, ap->a_uio);
}

/* Module init */
static int
mydev_modevent(module_t mod, int type, void *data)
{
    static cdev_t dev;

    switch (type) {
    case MOD_LOAD:
        dev = make_dev(&mydev_ops, 0, UID_ROOT, GID_WHEEL,
                       0600, "mydev");
        reference_dev(dev);
        break;
    case MOD_UNLOAD:
        destroy_dev(dev);
        break;
    }
    return 0;
}
```

## Cross-References

- [NewBus Framework](newbus.md) - Device/driver attachment model
- [Disk Layer](disk.md) - Block device and partition handling
- [Buffer Cache](vfs/buffer-cache.md) - BIO and buffer management
- [LWKT](lwkt.md) - Threading and MPSAFE concepts
