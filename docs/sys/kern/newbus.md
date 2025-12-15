# NewBus Framework

The NewBus framework is DragonFly BSD's device driver infrastructure, providing
a unified, object-oriented approach to device management. It handles device
enumeration, driver binding, resource allocation, and interrupt management.

**Source files:**
- `sys/kern/subr_bus.c` - Core NewBus implementation (~3,900 lines)
- `sys/kern/subr_autoconf.c` - Auto-configuration hooks
- `sys/kern/device_if.m` - Device interface methods
- `sys/kern/bus_if.m` - Bus interface methods
- `sys/sys/bus.h` - Public data structures and macros
- `sys/sys/bus_private.h` - Internal structures
- `sys/sys/kobj.h` - Kernel object system (method dispatch)

## Overview

NewBus derives from FreeBSD's NewBus but includes several DragonFly-specific
extensions:

1. **CPU Affinity** - Interrupt resources include CPU binding
2. **Asynchronous Probing** - Devices can probe/attach in parallel threads
3. **Global Probe Priority** - Fine-grained control over probe ordering
4. **LWKT Integration** - Uses LWKT threads for async operations
5. **Serializer Support** - Interrupt handlers can use LWKT serializers
6. **Threaded Interrupts Only** - No fast interrupts; all are threaded

## Data Structures

### device_t (struct bsd_device)

The fundamental device representation:

```c
struct bsd_device {
    KOBJ_FIELDS;                        /* kobj ops table */
    
    /* Device hierarchy */
    TAILQ_ENTRY(bsd_device) link;       /* list of devices in parent */
    TAILQ_ENTRY(bsd_device) devlink;    /* global device list */
    device_t        parent;
    device_list_t   children;           /* subordinate devices */
    
    /* Device details */
    driver_t       *driver;
    devclass_t      devclass;
    int             unit;
    char           *nameunit;           /* e.g., "em0" */
    char           *desc;               /* driver description */
    int             busy;               /* device_busy() count */
    device_state_t  state;
    uint32_t        devflags;           /* API-level flags */
    u_short         flags;              /* internal flags */
    u_char          order;              /* attachment order */
    void           *ivars;              /* bus-specific instance vars */
    void           *softc;              /* driver-specific data */
    
    struct sysctl_ctx_list sysctl_ctx;
    struct sysctl_oid *sysctl_tree;
};
```

Defined in `sys/sys/bus_private.h:97-139`.

### Device Flags

Internal flags (`flags` field):

| Flag | Value | Description |
|------|-------|-------------|
| `DF_ENABLED` | 0x0001 | Device should be probed/attached |
| `DF_FIXEDCLASS` | 0x0002 | Devclass specified at creation |
| `DF_WILDCARD` | 0x0004 | Unit originally wildcard (-1) |
| `DF_DESCMALLOCED` | 0x0008 | Description was allocated |
| `DF_QUIET` | 0x0010 | Don't print verbose attach message |
| `DF_DONENOMATCH` | 0x0020 | DEVICE_NOMATCH already called |
| `DF_EXTERNALSOFTC` | 0x0040 | softc not allocated by bus |
| `DF_ASYNCPROBE` | 0x0080 | Can probe with its own thread |

Defined in `sys/sys/bus_private.h:124-131`.

### device_state_t

Device lifecycle states:

```c
typedef enum device_state {
    DS_NOTPRESENT,    /* not probed or probe failed */
    DS_ALIVE,         /* probe succeeded */
    DS_INPROGRESS,    /* attach in progress (async) */
    DS_ATTACHED,      /* attach method called */
    DS_BUSY           /* device is open */
} device_state_t;
```

Defined in `sys/sys/bus.h:76-82`.

### devclass_t (struct devclass)

Groups devices by type (e.g., "pci", "em", "ahci"):

```c
struct devclass {
    TAILQ_ENTRY(devclass) link;
    devclass_t      parent;         /* parent devclass hierarchy */
    driver_list_t   drivers;        /* drivers for this bus type */
    char           *name;
    device_t       *devices;        /* array indexed by unit */
    int             maxunit;        /* devices array size */
    
    struct sysctl_ctx_list sysctl_ctx;
    struct sysctl_oid *sysctl_tree;
};
```

Defined in `sys/sys/bus_private.h:58-68`.

### driver_t (kobj_class_t)

Driver definition using the kobj class system:

```c
struct kobj_class {
    const char     *name;       /* driver name */
    kobj_method_t  *methods;    /* method table */
    size_t          size;       /* softc size */
    kobj_class_t   *baseclasses;/* inheritance */
    u_int           refs;       /* reference count */
    kobj_ops_t      ops;        /* compiled methods */
    u_int           gpri;       /* global probe priority */
};
```

**Global Probe Priorities** (`sys/sys/kobj.h:89-91`):

| Priority | Value | Description |
|----------|-------|-------------|
| `KOBJ_GPRI_ACPI` | 0x00FF | ACPI drivers probe first |
| `KOBJ_GPRI_DEFAULT` | 0x0000 | Default priority |
| `KOBJ_GPRI_LAST` | 0x0000 | Same as default |

Defined in `sys/sys/kobj.h:62-73`.

### struct resource

Represents allocated system resources:

```c
struct resource {
    TAILQ_ENTRY(resource) r_link;
    LIST_ENTRY(resource)  r_sharelink;
    LIST_HEAD(, resource) *r_sharehead;
    u_long          r_start;        /* first index */
    u_long          r_end;          /* last index (inclusive) */
    u_int           r_flags;
    void           *r_virtual;      /* virtual address */
    bus_space_tag_t r_bustag;
    bus_space_handle_t r_bushandle;
    device_t        r_dev;          /* owning device */
    struct rman    *r_rm;           /* resource manager */
    int             r_rid;          /* resource ID */
};
```

**Resource Flags** (`sys/sys/rman.h:45-52`):

| Flag | Value | Description |
|------|-------|-------------|
| `RF_ALLOCATED` | 0x0001 | Resource reserved |
| `RF_ACTIVE` | 0x0002 | Resource activated |
| `RF_SHAREABLE` | 0x0004 | Permits sharing |
| `RF_TIMESHARE` | 0x0008 | Permits time-division sharing |
| `RF_WANTED` | 0x0010 | Someone waiting |
| `RF_FIRSTSHARE` | 0x0020 | First in sharing list |
| `RF_PREFETCHABLE` | 0x0040 | Memory is prefetchable |
| `RF_OPTIONAL` | 0x0080 | For bus_alloc_resources() |

Defined in `sys/sys/rman.h:98-111`.

### Resource Types

```c
#define SYS_RES_IRQ     1   /* interrupt lines */
#define SYS_RES_DRQ     2   /* ISA DMA lines */
#define SYS_RES_MEMORY  3   /* I/O memory */
#define SYS_RES_IOPORT  4   /* I/O ports */
```

Defined in `sys/sys/bus_resource.h:41-44`.

### struct resource_list_entry

Bus-specific resource tracking:

```c
struct resource_list_entry {
    SLIST_ENTRY(resource_list_entry) link;
    int             type;       /* SYS_RES_* */
    int             rid;        /* resource identifier */
    struct resource *res;       /* actual resource */
    u_long          start;
    u_long          end;
    u_long          count;
    int             cpuid;      /* CPU affinity (DragonFly) */
};
```

Defined in `sys/sys/bus.h:136-146`.

## Device Interface Methods

Core methods that drivers implement (from `sys/kern/device_if.m`):

| Method | Purpose |
|--------|---------|
| `DEVICE_PROBE` | Check if driver supports device; return priority |
| `DEVICE_IDENTIFY` | Add child devices to bus (static method) |
| `DEVICE_ATTACH` | Initialize hardware and allocate resources |
| `DEVICE_DETACH` | Remove device and free resources |
| `DEVICE_SHUTDOWN` | Prepare for system shutdown |
| `DEVICE_SUSPEND` | Save state before power management suspend |
| `DEVICE_RESUME` | Restore state after resume |
| `DEVICE_QUIESCE` | FreeBSD compat: prepare for detach |
| `DEVICE_REGISTER` | Return device registration data |

### Probe Return Values

Drivers return priority values from `DEVICE_PROBE`:

| Value | Constant | Description |
|-------|----------|-------------|
| 0 | `BUS_PROBE_SPECIFIC` | Only this driver can use device |
| 0 | `BUS_PROBE_VENDOR` | Vendor-supplied driver |
| 0 | `BUS_PROBE_DEFAULT` | Standard driver |
| 0 | `BUS_PROBE_LOW_PRIORITY` | Lower priority match |
| 0 | `BUS_PROBE_GENERIC` | Generic fallback |
| 0 | `BUS_PROBE_HOOVER` | Catch-all device |

Note: In DragonFly, these are all defined as 0. Use `gpri` for priority
ordering instead.

See `sys/sys/bus.h:476-489`.

## Bus Interface Methods

Methods for bus drivers to manage children (from `sys/kern/bus_if.m`):

| Method | Purpose |
|--------|---------|
| `BUS_PRINT_CHILD` | Print device attachment info |
| `BUS_PROBE_NOMATCH` | Called when no driver matches |
| `BUS_READ_IVAR` / `BUS_WRITE_IVAR` | Read/write instance variables |
| `BUS_CHILD_DETACHED` | Notification of child detach |
| `BUS_DRIVER_ADDED` | New driver added notification |
| `BUS_ADD_CHILD` | Create child device |
| `BUS_ALLOC_RESOURCE` | Allocate system resource |
| `BUS_ACTIVATE_RESOURCE` | Activate resource |
| `BUS_DEACTIVATE_RESOURCE` | Deactivate resource |
| `BUS_RELEASE_RESOURCE` | Free resource |
| `BUS_SETUP_INTR` | Set up interrupt handler |
| `BUS_TEARDOWN_INTR` | Remove interrupt handler |
| `BUS_ENABLE_INTR` / `BUS_DISABLE_INTR` | Enable/disable interrupt |
| `BUS_SET_RESOURCE` | Set resource range |
| `BUS_GET_RESOURCE` | Get resource range |
| `BUS_DELETE_RESOURCE` | Delete resource |
| `BUS_GET_RESOURCE_LIST` | Get resource list |
| `BUS_CHILD_PRESENT` | Check if child hardware present |
| `BUS_CHILD_PNPINFO_STR` | Get PnP info string |
| `BUS_CHILD_LOCATION_STR` | Get location string |
| `BUS_CONFIG_INTR` | Configure interrupt trigger/polarity |
| `BUS_GET_DMA_TAG` | Get DMA tag |

## Device Lifecycle

### Device Creation

**device_add_child()** - `sys/kern/subr_bus.c:1240-1244`

Creates a new device as a child of an existing device:

```c
device_t device_add_child(device_t dev, const char *name, int unit);
```

- `name` - Driver name to use (NULL for any)
- `unit` - Unit number (-1 for auto-assignment)

**device_add_child_ordered()** - `sys/kern/subr_bus.c:1246-1281`

Creates a child with explicit attachment order:

```c
device_t device_add_child_ordered(device_t dev, int order,
                                  const char *name, int unit);
```

Lower order values are probed first.

**make_device()** - `sys/kern/subr_bus.c:1174-1225`

Internal function that:
1. Allocates `struct bsd_device`
2. Initializes kobj with null_class
3. Sets initial state to `DS_NOTPRESENT`
4. Adds to global `bus_data_devices` list

### Probe and Attach Flow

**device_probe_and_attach()** - `sys/kern/subr_bus.c:1961-2013`

Main entry point for device attachment:

1. Check if already alive
2. Check if enabled
3. Call `device_probe_child()`
4. On probe failure, call `BUS_PROBE_NOMATCH`
5. Print device info if verbose
6. Either attach async or sync

**device_probe_child()** - `sys/kern/subr_bus.c:1403-1489`

Finds the best matching driver:

1. Get parent's devclass
2. Iterate through devclass hierarchy
3. For each driver:
   - Set driver on device
   - Call `DEVICE_PROBE()`
   - Track best match by priority
4. Set device to best driver
5. Change state to `DS_ALIVE`

**device_doattach()** - `sys/kern/subr_bus.c:2098-2124`

Performs actual attachment:

1. Initialize sysctl tree
2. Call `DEVICE_ATTACH()`
3. On success: set state to `DS_ATTACHED`, notify devctl
4. On failure: restore to `DS_NOTPRESENT`

### Asynchronous Attachment (DragonFly Extension)

Enabled by `kern.do_async_attach` tunable.

**device_attach_async()** - `sys/kern/subr_bus.c:2071-2093`

```c
static void
device_attach_async(device_t dev)
{
    atomic_add_int(&numasyncthreads, 1);
    lwkt_create(device_attach_thread, dev, &td, NULL,
                0, 0, "%s", (dev->desc ? dev->desc : "devattach"));
}
```

Devices must set `DF_ASYNCPROBE` flag to use async attach.

### Detach

**device_detach()** - `sys/kern/subr_bus.c:2126-2152`

1. Check if busy
2. Call `DEVICE_DETACH()`
3. Notify devctl
4. Call `BUS_CHILD_DETACHED()`
5. Remove from devclass if not fixed
6. Set state to `DS_NOTPRESENT`
7. Clear driver

## Resource Allocation

### Allocating Resources

**bus_alloc_resource()** - `sys/kern/subr_bus.c:3290-3298`

```c
struct resource *
bus_alloc_resource(device_t dev, int type, int *rid,
                   u_long start, u_long end, u_long count, u_int flags);
```

- `type` - `SYS_RES_IRQ`, `SYS_RES_MEMORY`, `SYS_RES_IOPORT`, `SYS_RES_DRQ`
- `rid` - Resource ID (in/out)
- `start`, `end` - Requested range (0, ~0 for any)
- `count` - Number of units
- `flags` - `RF_*` flags

**bus_alloc_resource_any()** - `sys/sys/bus.h:345-349` (inline)

Convenience wrapper:

```c
static __inline struct resource *
bus_alloc_resource_any(device_t dev, int type, int *rid, u_int flags)
{
    return (bus_alloc_resource(dev, type, rid, 0ul, ~0ul, 1, flags));
}
```

**bus_alloc_legacy_irq_resource()** - `sys/kern/subr_bus.c:3300-3307`

DragonFly-specific: Allocates IRQ with CPU affinity:

```c
struct resource *
bus_alloc_legacy_irq_resource(device_t dev, int *rid, u_long irq, u_int flags);
```

### Activating Resources

**bus_activate_resource()** - `sys/kern/subr_bus.c:3309-3315`

Maps the resource (for memory/I/O port) or enables it (for IRQ).

**bus_deactivate_resource()** - `sys/kern/subr_bus.c:3317-3323`

Unmaps or disables the resource.

### Releasing Resources

**bus_release_resource()** - `sys/kern/subr_bus.c:3325-3331`

Frees a previously allocated resource.

### Resource List Management

Buses use resource lists to track child resources:

| Function | Purpose |
|----------|---------|
| `resource_list_init()` | Initialize list |
| `resource_list_free()` | Free list and all entries |
| `resource_list_add()` | Add resource to list |
| `resource_list_find()` | Find resource by type/rid |
| `resource_list_delete()` | Remove resource from list |
| `resource_list_alloc()` | Allocate from list |
| `resource_list_release()` | Release resource |

See `sys/kern/subr_bus.c:2592-2746`.

## Interrupt Handling

### Interrupt Flags

```c
#define INTR_HIFREQ     0x0040  /* high frequency interrupt */
#define INTR_CLOCK      0x0080  /* clock interrupt */
#define INTR_EXCL       0x0100  /* exclusive, non-shared */
#define INTR_MPSAFE     0x0200  /* handler is MP-safe */
#define INTR_NOENTROPY  0x0400  /* don't add to entropy pool */
#define INTR_NOPOLL     0x0800  /* cannot be polled */
```

Note: `INTR_FAST` is no longer supported - all device interrupts are threaded.

Defined in `sys/sys/bus.h:109-114`.

### Interrupt Trigger and Polarity

```c
enum intr_trigger {
    INTR_TRIGGER_CONFORM = 0,
    INTR_TRIGGER_EDGE = 1,
    INTR_TRIGGER_LEVEL = 2
};

enum intr_polarity {
    INTR_POLARITY_CONFORM = 0,
    INTR_POLARITY_HIGH = 1,
    INTR_POLARITY_LOW = 2
};
```

Defined in `sys/sys/bus.h:116-126`.

### Setting Up Interrupts

**bus_setup_intr()** - `sys/kern/subr_bus.c:3344-3351`

```c
int bus_setup_intr(device_t dev, struct resource *r, int flags,
                   driver_intr_t handler, void *arg, void **cookiep,
                   lwkt_serialize_t serializer);
```

- `r` - IRQ resource from `bus_alloc_resource()`
- `flags` - `INTR_*` flags
- `handler` - Interrupt handler function
- `arg` - Argument passed to handler
- `cookiep` - Returns cookie for teardown
- `serializer` - Optional LWKT serializer (DragonFly extension)

**bus_setup_intr_descr()** - `sys/kern/subr_bus.c:3333-3342`

Same as above but with description string for debugging.

### Tearing Down Interrupts

**bus_teardown_intr()** - `sys/kern/subr_bus.c:3353-3359`

```c
int bus_teardown_intr(device_t dev, struct resource *r, void *cookie);
```

### Enabling/Disabling Interrupts

**bus_enable_intr()** - `sys/kern/subr_bus.c:3361-3366`
**bus_disable_intr()** - `sys/kern/subr_bus.c:3368-3375`

## Devclass Management

### Finding/Creating Devclasses

**devclass_find()** - `sys/kern/subr_bus.c:789-793`

Finds an existing devclass by name.

**devclass_create()** - `sys/kern/subr_bus.c:783-787`

Finds or creates a devclass.

**devclass_find_internal()** - `sys/kern/subr_bus.c:738-781`

Internal function that:
1. Searches global `devclasses` list
2. Creates if not found and `create` is true
3. Handles parent devclass for inheritance

### Driver Registration

**devclass_add_driver()** - `sys/kern/subr_bus.c:805-850`

Adds a driver to a devclass:

1. Instantiate driver kobj class
2. Create devclass for driver name
3. Add to devclass driver list
4. Call `BUS_DRIVER_ADDED` for existing buses

**devclass_delete_driver()** - `sys/kern/subr_bus.c:852-906`

Removes a driver:

1. Find driver link
2. Detach all devices using driver
3. Remove from driver list
4. Uninstantiate kobj class

## Generic Bus Methods

Standard implementations for bus drivers in `sys/kern/subr_bus.c`:

| Function | Line | Purpose |
|----------|------|---------|
| `bus_generic_identify` | 2786 | Add child with driver name |
| `bus_generic_identify_sameunit` | 2795 | Add child with parent's unit |
| `bus_generic_probe` | 2807 | Call DEVICE_IDENTIFY for all drivers |
| `bus_generic_attach` | 2840 | Probe/attach all children |
| `bus_generic_attach_gpri` | 2852 | Attach with specific priority |
| `bus_generic_detach` | 2864 | Detach all children |
| `bus_generic_shutdown` | 2880 | Shutdown all children |
| `bus_generic_suspend` | 2891 | Suspend all children (with rollback) |
| `bus_generic_resume` | 2910 | Resume all children |
| `bus_generic_print_child` | 2958 | Print header + footer |
| `bus_generic_driver_added` | 3004 | Try attaching unprobed children |
| `bus_generic_setup_intr` | 3016 | Propagate to parent |
| `bus_generic_teardown_intr` | 3030 | Propagate to parent |
| `bus_generic_alloc_resource` | 3068 | Propagate to parent |
| `bus_generic_release_resource` | 3080 | Propagate to parent |

## Configuration Resource Hints

Support for device hints from `/boot/loader.conf`:

**resource_int_value()** - `sys/kern/subr_bus.c:2325-2342`
**resource_long_value()** - `sys/kern/subr_bus.c:2344-2362`
**resource_string_value()** - `sys/kern/subr_bus.c:2364-2397`

```c
int resource_int_value(const char *name, int unit,
                       const char *resname, int *result);
```

**resource_kenv()** - `sys/kern/subr_bus.c:2298-2323`

Supports both DragonFly and FreeBSD hint formats:
- DragonFly: `deviceN.property`
- FreeBSD: `hint.device.N.property`

**resource_disabled()** - `sys/kern/subr_bus.c:3818-3827`

```c
int resource_disabled(const char *name, int unit);
```

Checks if `deviceN.disabled=1` is set.

## Auto-Configuration Hooks

For drivers that need interrupt-driven configuration:

### struct intr_config_hook

```c
struct intr_config_hook {
    TAILQ_ENTRY(intr_config_hook) ich_links;
    void    (*ich_func)(void *);
    void    *ich_arg;
    const char *ich_desc;
    int     ich_order;
    int     ich_ran;
};
```

Defined in `sys/sys/kernel.h:475-482`.

### API Functions

**config_intrhook_establish()** - `sys/kern/subr_autoconf.c:136-177`

Registers hook for post-interrupt configuration:
- Hooks ordered by `ich_order`
- If called after boot, runs immediately

**config_intrhook_disestablish()** - `sys/kern/subr_autoconf.c:179-201`

Removes hook and wakes up waiters.

**run_interrupt_driven_config_hooks()** - `sys/kern/subr_autoconf.c:64-127`

Called at `SI_SUB_INT_CONFIG_HOOKS`:
- Runs each hook function
- Waits for hooks to complete (with timeout warnings)
- USB hack: waits extra 5 seconds for USB devices

## Root Bus

The root bus is the top of the device tree:

```c
static driver_t root_driver = {
    "root",
    root_methods,
    1,  /* no softc */
};

device_t    root_bus;
devclass_t  root_devclass;
```

Defined in `sys/kern/subr_bus.c:3523-3560`.

**root_bus_configure()** - `sys/kern/subr_bus.c:3562-3603`

Called during boot to:
1. Call `bus_generic_probe()` for root bus
2. Probe and attach children (typically nexus)
3. Wait for async attaches

## devctl Device

Character device `/dev/devctl` for userland notification:

**Events Sent:**
- `devadded()` - Device attached successfully
- `devremoved()` - Device about to detach
- `devnomatch()` - No driver found

**devctl_notify()** - `sys/kern/subr_bus.c:529-559`

Standard notification format:
```
!system=<system> subsystem=<subsystem> type=<type> [data]
```

See `sys/kern/subr_bus.c:250-721`.

## Sysctl Interface

**hw.bus.info** - Returns bus generation count
**hw.bus.devices** - Returns device tree

`struct u_device` (`sys/sys/bus.h:87-100`) exported to userspace.

See `sys/kern/subr_bus.c:3843-3907`.

## Driver Definition Macros

**DRIVER_MODULE** - `sys/sys/bus.h:518-538`

```c
#define DRIVER_MODULE(name, busname, driver, devclass, evh, arg)    \
    DRIVER_MODULE_ORDERED(name, busname, driver, &devclass, evh, arg,\
                          SI_ORDER_MIDDLE)
```

**DEVMETHOD / DEVMETHOD_END** - `sys/sys/bus.h:494-495`

```c
#define DEVMETHOD       KOBJMETHOD
#define DEVMETHOD_END   KOBJMETHOD_END
```

## Bus Space Access

Shorthand macros for `bus_space_*` functions:

```c
bus_read_1(r, o)    /* read 1 byte */
bus_read_2(r, o)    /* read 2 bytes */
bus_read_4(r, o)    /* read 4 bytes */
bus_write_1(r, o, v)
bus_write_2(r, o, v)
bus_write_4(r, o, v)
bus_read_region_N()
bus_write_region_N()
bus_set_region_N()
bus_copy_region_N()
bus_barrier()
```

See `sys/sys/bus.h:563-692`.

## Example: Simple PCI Driver

```c
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/bus.h>
#include <bus/pci/pcivar.h>

static int
mydev_probe(device_t dev)
{
    if (pci_get_vendor(dev) == 0x1234 &&
        pci_get_device(dev) == 0x5678) {
        device_set_desc(dev, "My Device");
        return BUS_PROBE_DEFAULT;
    }
    return ENXIO;
}

static int
mydev_attach(device_t dev)
{
    struct mydev_softc *sc = device_get_softc(dev);
    int rid;
    
    /* Allocate BAR0 */
    rid = PCIR_BAR(0);
    sc->mem_res = bus_alloc_resource_any(dev, SYS_RES_MEMORY,
                                         &rid, RF_ACTIVE);
    if (sc->mem_res == NULL)
        return ENXIO;
    
    /* Allocate interrupt */
    rid = 0;
    sc->irq_res = bus_alloc_resource_any(dev, SYS_RES_IRQ,
                                         &rid, RF_ACTIVE | RF_SHAREABLE);
    if (sc->irq_res == NULL) {
        bus_release_resource(dev, SYS_RES_MEMORY, PCIR_BAR(0), sc->mem_res);
        return ENXIO;
    }
    
    /* Setup interrupt handler */
    bus_setup_intr(dev, sc->irq_res, INTR_MPSAFE,
                   mydev_intr, sc, &sc->irq_cookie, NULL);
    
    return 0;
}

static int
mydev_detach(device_t dev)
{
    struct mydev_softc *sc = device_get_softc(dev);
    
    bus_teardown_intr(dev, sc->irq_res, sc->irq_cookie);
    bus_release_resource(dev, SYS_RES_IRQ, 0, sc->irq_res);
    bus_release_resource(dev, SYS_RES_MEMORY, PCIR_BAR(0), sc->mem_res);
    
    return 0;
}

static device_method_t mydev_methods[] = {
    DEVMETHOD(device_probe,     mydev_probe),
    DEVMETHOD(device_attach,    mydev_attach),
    DEVMETHOD(device_detach,    mydev_detach),
    DEVMETHOD_END
};

static driver_t mydev_driver = {
    "mydev",
    mydev_methods,
    sizeof(struct mydev_softc)
};

static devclass_t mydev_devclass;

DRIVER_MODULE(mydev, pci, mydev_driver, mydev_devclass, NULL, NULL);
```

## Cross-References

- [Device Framework](devices.md) - Character/block device layer
- [Resource Management](resources.md) - rman and DMA
- [LWKT](lwkt.md) - Threading and serializers
- [Synchronization](synchronization.md) - Locking primitives
