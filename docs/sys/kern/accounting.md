# Accounting, Sensors, and Watchdog

This document covers kernel subsystems for system monitoring and resource tracking:
process accounting records resource usage for completed processes, the hardware
sensor framework collects environmental data from device drivers, and the watchdog
subsystem prevents system hangs through timer-based monitoring.

**Source files:**
- `sys/kern/kern_acct.c` - Process accounting
- `sys/kern/kern_sensors.c` - Hardware sensor framework
- `sys/kern/kern_wdog.c` - Watchdog timer support

## Process Accounting

Process accounting writes a record to a designated file each time a process exits,
capturing resource usage statistics. This BSD-standard mechanism allows system
administrators to track command execution, CPU time, and I/O activity.

### The acct Structure

Each accounting record uses a fixed-format structure (`sys/acct.h:53`):

```c
struct acct {
    char      ac_comm[16];   /* command name */
    comp_t    ac_utime;      /* user time */
    comp_t    ac_stime;      /* system time */
    comp_t    ac_etime;      /* elapsed time */
    time_t    ac_btime;      /* starting time */
    uid_t     ac_uid;        /* user id */
    gid_t     ac_gid;        /* group id */
    u_int16_t ac_mem;        /* average memory usage */
    comp_t    ac_io;         /* count of IO blocks */
    dev_t     ac_tty;        /* controlling tty */
    u_int8_t  ac_flag;       /* accounting flags */
};
```

The `comp_t` type is a compressed floating-point representation using a 3-bit
base-8 exponent and 13-bit mantissa, providing compact storage for time values
in units of 1/64 seconds (AHZ = 64).

### Accounting Flags

| Flag | Value | Description |
|------|-------|-------------|
| `AFORK` | 0x01 | Process forked but never exec'd |
| `ASU` | 0x02 | Used superuser permissions |
| `ACOMPAT` | 0x04 | Used compatibility mode |
| `ACORE` | 0x08 | Dumped core on exit |
| `AXSIG` | 0x10 | Killed by a signal |

### Enabling Accounting

The `acct()` system call enables or disables process accounting
(`kern_acct.c:122`):

```c
int sys_acct(struct sysmsg *sysmsg, const struct acct_args *uap)
{
    /* Requires SYSCAP_NOACCT capability */
    error = caps_priv_check_self(SYSCAP_NOACCT);
    
    if (uap->path != NULL) {
        /* Open file for append, must be regular file */
        error = nlookup_init(&nd, uap->path, UIO_USERSPACE, NLC_LOCKVP);
        error = vn_open(&nd, NULL, FWRITE | O_APPEND, 0);
        if (nd.nl_open_vp->v_type != VREG)
            error = EACCES;
    }
    
    /* Close previous accounting file if any */
    if (acctp != NULLVP || savacctp != NULLVP) {
        callout_stop(&acctwatch_handle);
        vn_close(...);
    }
    
    /* Start space watcher for new file */
    acctp = vp;
    acctwatch(NULL);
}
```

### Writing Accounting Records

The `acct_process()` function writes an accounting record on process exit
(`kern_acct.c:196`):

```c
int acct_process(struct proc *p)
{
    struct acct acct;
    
    /* Skip if accounting disabled */
    if (acctp == NULLVP)
        return 0;
    
    /* (1) Command name */
    bcopy(p->p_comm, acct.ac_comm, sizeof acct.ac_comm);
    
    /* (2) User and system time */
    calcru_proc(p, &ru);
    acct.ac_utime = encode_comp_t(ru.ru_utime.tv_sec, ru.ru_utime.tv_usec);
    acct.ac_stime = encode_comp_t(ru.ru_stime.tv_sec, ru.ru_stime.tv_usec);
    
    /* (3) Elapsed time and start time */
    acct.ac_btime = p->p_start.tv_sec;
    acct.ac_etime = encode_comp_t(elapsed.tv_sec, elapsed.tv_usec);
    
    /* (4) Average memory usage */
    acct.ac_mem = (r->ru_ixrss + r->ru_idrss + r->ru_isrss) / t;
    
    /* (5) I/O block count */
    acct.ac_io = encode_comp_t(r->ru_inblock + r->ru_oublock, 0);
    
    /* (6) UID and GID */
    acct.ac_uid = p->p_ucred->cr_ruid;
    acct.ac_gid = p->p_ucred->cr_rgid;
    
    /* (7) Controlling terminal */
    acct.ac_tty = devid_from_dev(p->p_pgrp->pg_session->s_ttyp->t_dev);
    
    /* (8) Process flags */
    acct.ac_flag = p->p_acflag;
    
    /* Write record (with no file size limit) */
    vn_rdwr(UIO_WRITE, vp, &acct, sizeof(acct), 0,
            UIO_SYSSPACE, IO_APPEND|IO_UNIT, ...);
}
```

### Disk Space Monitoring

The accounting subsystem monitors available disk space and suspends accounting
when space runs low (`kern_acct.c:329`):

```c
static void acctwatch(void *a)
{
    VFS_STATFS(acctp->v_mount, &sb, proc0.p_ucred);
    
    if (sb.f_bavail <= acctsuspend * sb.f_blocks / 100) {
        /* Suspend accounting when below threshold */
        savacctp = acctp;
        acctp = NULLVP;
        log(LOG_NOTICE, "Accounting suspended\n");
    }
    
    /* Reschedule check */
    callout_reset(&acctwatch_handle, acctchkfreq * hz, acctwatch, NULL);
}
```

### Accounting Sysctls

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kern.acct_suspend` | 2 | Suspend when free space below this % |
| `kern.acct_resume` | 4 | Resume when free space above this % |
| `kern.acct_chkfreq` | 15 | Space check frequency (seconds) |

---

## Hardware Sensor Framework

The sensor framework provides a unified interface for hardware monitoring devices
to report environmental data (temperature, voltage, fan speed, etc.) through the
sysctl tree. Originally from OpenBSD, this framework supports per-CPU sensor
task scheduling for efficient data collection.

### Sensor Types

The framework supports many sensor types (`sys/sensors.h:35`):

| Type | Sysctl Name | Unit | Description |
|------|-------------|------|-------------|
| `SENSOR_TEMP` | temp | µK | Temperature (microkelvin) |
| `SENSOR_FANRPM` | fan | RPM | Fan speed |
| `SENSOR_VOLTS_DC` | volt | µV | DC voltage |
| `SENSOR_VOLTS_AC` | acvolt | µV | AC voltage |
| `SENSOR_OHMS` | resistance | Ω | Resistance |
| `SENSOR_WATTS` | power | W | Power |
| `SENSOR_AMPS` | current | µA | Current |
| `SENSOR_WATTHOUR` | watthour | Wh | Energy capacity |
| `SENSOR_AMPHOUR` | amphour | Ah | Charge capacity |
| `SENSOR_INDICATOR` | indicator | bool | Boolean state |
| `SENSOR_INTEGER` | raw | - | Generic integer |
| `SENSOR_PERCENT` | percent | % | Percentage |
| `SENSOR_LUX` | illuminance | mlx | Light level |
| `SENSOR_DRIVE` | drive | - | Disk status |
| `SENSOR_TIMEDELTA` | timedelta | ns | Time error |
| `SENSOR_ECC` | ecc | - | Memory ECC errors |
| `SENSOR_FREQ` | freq | Hz | Frequency |

### Sensor Status

Each sensor reports its health status:

```c
enum sensor_status {
    SENSOR_S_UNSPEC,    /* status unspecified */
    SENSOR_S_OK,        /* normal operation */
    SENSOR_S_WARN,      /* warning threshold */
    SENSOR_S_CRIT,      /* critical threshold */
    SENSOR_S_UNKNOWN    /* status unknown */
};
```

### Data Structures

**Kernel sensor** (`sys/sensors.h:142`):

```c
struct ksensor {
    SLIST_ENTRY(ksensor) list;   /* device sensor list */
    char desc[32];               /* description */
    struct timeval tv;           /* last update time */
    int64_t value;               /* current value */
    enum sensor_type type;       /* sensor type */
    enum sensor_status status;   /* health status */
    int numt;                    /* index within type */
    int flags;                   /* SENSOR_FINVALID, SENSOR_FUNKNOWN */
    struct sysctl_oid *oid;      /* sysctl node */
};
```

**Sensor device** (`sys/sensors.h:156`):

```c
struct ksensordev {
    TAILQ_ENTRY(ksensordev) list;
    int num;                          /* device number */
    char xname[16];                   /* device name (e.g., "cpu0") */
    int maxnumt[SENSOR_MAX_TYPES];    /* count per type */
    int sensors_count;                /* total sensors */
    struct ksensors_head sensors_list;
    struct sysctl_oid *oid;           /* sysctl node */
    struct sysctl_ctx_list clist;     /* sysctl context */
};
```

### Device Registration

Drivers register sensor devices to make sensors visible (`kern_sensors.c:78`):

```c
void sensordev_install(struct ksensordev *sensdev)
{
    SYSCTL_XLOCK();
    
    /* Find next available device number */
    TAILQ_FOREACH(v, &sensordev_list, list) {
        if (v->num == num)
            ++num;
        else if (v->num > num)
            break;
    }
    sensdev->num = num;
    
    /* Insert into list */
    TAILQ_INSERT_AFTER(&sensordev_list, after, sensdev, list);
    
    /* Create sysctl node: hw.sensors.<device> */
    sensordev_sysctl_install(sensdev);
    
    SYSCTL_XUNLOCK();
}
```

### Sensor Attachment

Individual sensors are attached to devices (`kern_sensors.c:112`):

```c
void sensor_attach(struct ksensordev *sensdev, struct ksensor *sens)
{
    SYSCTL_XLOCK();
    
    /* Assign sensor number within type */
    /* Sensors of same type are kept consecutive */
    sens->numt = v->numt + 1;  /* or 0 if first of type */
    
    SLIST_INSERT_AFTER(v, sens, list);
    sensdev->maxnumt[sens->type]++;
    sensdev->sensors_count++;
    
    /* Create sysctl: hw.sensors.<device>.<type><n> */
    sensor_sysctl_install(sensdev, sens);
    
    SYSCTL_XUNLOCK();
}
```

### Task Scheduling

Sensor drivers use periodic tasks to poll hardware. Tasks are distributed
across CPUs for efficiency (`kern_sensors.c:269`):

```c
struct sensor_task *
sensor_task_register2(void *arg, void (*func)(void *), int period, int cpu)
{
    if (cpu < 0)
        cpu = sensor_task_default_cpu;  /* Usually first package CPU */
    
    thr = &sensor_task_threads[cpu];
    
    st = kmalloc(sizeof(struct sensor_task), M_DEVBUF, M_WAITOK);
    st->arg = arg;
    st->func = func;
    st->period = period;
    st->cpuid = cpu;
    st->running = 1;
    st->nextrun = 0;  /* Run immediately */
    
    TAILQ_INSERT_HEAD(&thr->list, st, entry);
    wakeup(&thr->list);
    
    return st;
}
```

Each CPU runs a sensor task thread that processes its task list
(`kern_sensors.c:300`):

```c
static void sensor_task_thread(void *xthr)
{
    for (;;) {
        /* Wait for tasks */
        while (TAILQ_EMPTY(&thr->list))
            lksleep(&thr->list, &thr->lock, 0, "waittask", 0);
        
        /* Wait until next task is due */
        while (nst->nextrun > time_uptime)
            lksleep(&thr->list, &thr->lock, 0, "timeout",
                    (nst->nextrun - now) * hz);
        
        /* Run due tasks */
        TAILQ_FOREACH_SAFE(st, &thr->list, entry, nst) {
            if (st->nextrun > now)
                break;
            
            TAILQ_REMOVE(&thr->list, st, entry);
            
            if (!st->running) {
                kfree(st, M_DEVBUF);
                continue;
            }
            
            st->func(st->arg);           /* Poll hardware */
            sensor_task_schedule(thr, st); /* Reschedule */
        }
    }
}
```

### Sysctl Interface

Sensors appear under `hw.sensors`:

```
hw.sensors.cpu0.temp0           # First temperature sensor on cpu0
hw.sensors.acpi_tz0.temp0       # ACPI thermal zone temperature
hw.sensors.aibs0.volt0          # First voltage sensor
hw.sensors.dev_idmax            # Maximum sensor device ID
```

The legacy MIB interface (`hw._sensors`) supports OpenBSD-compatible access
(`kern_sensors.c:499`):

```c
static int sysctl_sensors_handler(SYSCTL_HANDLER_ARGS)
{
    /* name[0] = device, name[1] = type, name[2] = numt */
    if (namelen == 1)
        return sysctl_handle_sensordev(...);  /* Return device info */
    
    type = name[1];
    numt = name[2];
    ks = sensor_find(ksd, type, numt);
    return sysctl_handle_sensor(...);  /* Return sensor data */
}
```

### Helper Functions

Convenience functions for setting sensor values (`sys/sensors.h:191`):

```c
/* Mark sensor as invalid (hardware error) */
static inline void sensor_set_invalid(struct ksensor *sens);

/* Mark sensor value as unknown */
static inline void sensor_set_unknown(struct ksensor *sens);

/* Set sensor value and status */
static inline void sensor_set(struct ksensor *sens, int64_t val,
                              enum sensor_status status);

/* Set temperature from degrees Celsius */
static inline void sensor_set_temp_degc(struct ksensor *sens, int degc,
                                        enum sensor_status status);
```

### Driver Example

A typical sensor driver pattern:

```c
struct mydev_softc {
    struct ksensordev sensordev;
    struct ksensor temp_sensor;
    struct sensor_task *task;
};

static void mydev_refresh(void *arg)
{
    struct mydev_softc *sc = arg;
    int temp = read_hw_temp(sc);
    
    /* Temperature in microkelvin: (degC * 1000000) + 273150000 */
    sensor_set_temp_degc(&sc->temp_sensor, temp, SENSOR_S_OK);
}

static int mydev_attach(device_t dev)
{
    struct mydev_softc *sc = device_get_softc(dev);
    
    strlcpy(sc->sensordev.xname, device_get_nameunit(dev),
            sizeof(sc->sensordev.xname));
    
    sc->temp_sensor.type = SENSOR_TEMP;
    strlcpy(sc->temp_sensor.desc, "CPU temperature",
            sizeof(sc->temp_sensor.desc));
    sensor_attach(&sc->sensordev, &sc->temp_sensor);
    
    sensordev_install(&sc->sensordev);
    
    /* Poll every 5 seconds on default CPU */
    sc->task = sensor_task_register2(sc, mydev_refresh, 5, -1);
}
```

---

## Watchdog Timer Support

The watchdog subsystem manages hardware watchdog timers that reset the system
if not periodically serviced. This prevents system hangs by ensuring the kernel
remains responsive.

### Watchdog Structure

Drivers register watchdog devices using (`sys/wdog.h:47`):

```c
typedef int (wdog_fn)(void *, int);

struct watchdog {
    const char *name;       /* watchdog name */
    wdog_fn *wdog_fn;       /* reset function */
    void *arg;              /* driver argument */
    int period_max;         /* maximum period (seconds) */
    
    /* Internal fields */
    int period;             /* current period */
    LIST_ENTRY(watchdog) link;
};
```

The reset function receives the argument and requested period, returning the
actual period set (which may be clamped to hardware limits).

### Registration

Watchdog drivers register with the framework (`kern_wdog.c:60`):

```c
void wdog_register(struct watchdog *wd)
{
    spin_lock(&wdogmtx);
    wd->period = WDOG_DEFAULT_PERIOD;  /* 30 seconds */
    LIST_INSERT_HEAD(&wdoglist, wd, link);
    spin_unlock(&wdogmtx);
    
    wdog_reset_all(NULL);  /* Start watchdog immediately */
    
    kprintf("wdog: Watchdog %s registered, max period = %ds\n",
            wd->name, wd->period_max);
}
```

### Automatic Reset

By default, the kernel automatically resets all watchdogs before they expire
(`kern_wdog.c:90`):

```c
static void wdog_reset_all(void *unused)
{
    int min_period = INT_MAX;
    
    spin_lock(&wdogmtx);
    
    LIST_FOREACH(wd, &wdoglist, link) {
        period = wdog_reset(wd);  /* Call driver */
        if (period < min_period)
            min_period = period;
    }
    
    if (wdog_auto_enable) {
        /* Reset at half the minimum period */
        callout_reset(&wdog_callout, min_period * hz / 2,
                      wdog_reset_all, NULL);
    }
    
    spin_unlock(&wdogmtx);
}
```

### Sysctl Interface

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kern.watchdog.auto` | 1 | Enable automatic kernel reset |
| `kern.watchdog.period` | 30 | Watchdog period (seconds) |

When `kern.watchdog.auto` is disabled, userspace must reset the watchdog via
the `/dev/wdog` device.

### Device Interface

The `/dev/wdog` device provides userspace watchdog control (`kern_wdog.c:188`):

```c
static int wdog_ioctl(struct dev_ioctl_args *ap)
{
    if (wdog_auto_enable)
        return EINVAL;  /* Must disable auto-reset first */
    
    if (ap->a_cmd == WDIOCRESET) {
        wdog_reset_all(NULL);
        return 0;
    }
    return EINVAL;
}
```

Userspace usage pattern:

```c
int fd = open("/dev/wdog", O_RDWR);

/* Disable kernel auto-reset via sysctl first */
sysctlbyname("kern.watchdog.auto", NULL, NULL, &zero, sizeof(zero));

/* Reset watchdog periodically */
while (running) {
    ioctl(fd, WDIOCRESET, NULL);
    sleep(period / 2);
}
```

### Disabling Watchdogs

The `wdog_disable()` function stops all watchdog timers (`kern_wdog.c:171`):

```c
void wdog_disable(void)
{
    callout_stop(&wdog_callout);
    wdog_set_period(0);  /* Period 0 disables hardware */
    wdog_reset_all(NULL);
}
```

This is called during controlled shutdown to prevent spurious resets.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Applications                          │
│              (monitoring daemons)                        │
└─────────────────────────────────────────────────────────┘
                         │ ioctl(WDIOCRESET)
                         ▼
┌─────────────────────────────────────────────────────────┐
│                     /dev/wdog                            │
│                   (if auto=0)                            │
└─────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              Watchdog Framework                          │
│   ┌─────────────────────────────────────────────────┐   │
│   │  wdog_callout (auto reset @ period/2)           │   │
│   └─────────────────────────────────────────────────┘   │
│                         │                                │
│                         ▼                                │
│   ┌─────────────────────────────────────────────────┐   │
│   │              wdoglist                            │   │
│   │  ┌─────────┐  ┌─────────┐  ┌─────────┐         │   │
│   │  │  ichwd  │──│ amdsbwd │──│  other  │         │   │
│   │  └─────────┘  └─────────┘  └─────────┘         │   │
│   └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              Hardware Watchdog Timers                    │
│     (chipset-specific countdown timers)                  │
└─────────────────────────────────────────────────────────┘
```

---

## See Also

- [Sysctl Framework](sysctl.md) - MIB tree for sensor and watchdog sysctls
- [Tracing](tracing.md) - KTR ring buffers for debugging
- [Devices](devices.md) - Device driver framework
- [Time Keeping](time.md) - Callout infrastructure for periodic tasks
