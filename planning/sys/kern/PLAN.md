# `sys/kern/` Reading and Documentation Plan

This plan organizes the DragonFly BSD kernel core (`sys/kern/`) into logical reading phases. The directory contains ~180 implementation files grouped by subsystem prefix, plus two subdirectories (`libmchain/`, `firmware/`).

## Overview of `sys/kern/` subsystems

The files cluster into these major subsystem groups:

### Core infrastructure (foundational, read first)
- **LWKT** (`lwkt_*`, 5 files) — DragonFly's lightweight kernel threading, message ports, tokens, IPIs, serialization
- **Initialization** (`init_main.c`, `init_sysent.c`) — kernel bootstrap and system call table initialization
- **Synchronization primitives** (`kern_condvar.c`, `kern_lock.c`, `kern_mutex.c`, `kern_refcount.c`, `kern_spinlock.c`, `kern_sysref.c`, `kern_umtx.c`, `subr_sleepqueue.c`) — locks, condition variables, refcounts
- **Time and scheduling** (`kern_clock.c`, `kern_cputimer.c`, `kern_ntptime.c`, `kern_sched.c`, `kern_synch.c`, `kern_systimer.c`, `kern_time.c`, `kern_timeout.c`, `usched_*.c`) — timekeeping, timers, process/thread scheduling

### Memory management and allocation
- **Kernel allocators** (`kern_kmalloc.c`, `kern_slaballoc.c`, `kern_objcache.c`, `kern_mpipe.c`) — malloc, slab allocator, object caches, message pipes
- **Memory utilities** (`kern_sfbuf.c`, `subr_alist.c`, `subr_blist.c`, `subr_rbtree.c`) — transient mappings, allocation lists, bitmaps, red-black trees
- **Buffer management** (`subr_sbuf.c`, `subr_sglist.c`) — string buffers, scatter-gather lists

### Process and thread management
- **Process lifecycle** (`kern_exec.c`, `kern_exit.c`, `kern_fork.c`, `kern_proc.c`, `kern_threads.c`, `kern_kthread.c`) — exec, exit, fork, process/thread structures, kernel threads
- **Process resources** (`kern_plimit.c`, `kern_resource.c`, `kern_prot.c`, `kern_descrip.c`) — limits, resource usage, credentials, file descriptors
- **Signals** (`kern_sig.c`) — signal delivery and handling
- **Image activators** (`imgact_*.c`, 3 files) — ELF, shell script, resident image loading

### Virtual filesystem (VFS) layer
- **VFS core** (`vfs_init.c`, `vfs_conf.c`, `vfs_default.c`, `vfs_subr.c`, `vfs_vfsops.c`, `vfs_vnops.c`, `vfs_vopops.c`) — VFS initialization, filesystem registration, vnode operations
- **Name lookup** (`vfs_cache.c`, `vfs_lookup.c`, `vfs_nlookup.c`) — name cache, path resolution
- **Mounting** (`vfs_mount.c`, `vfs_syscalls.c`) — mount/unmount, VFS syscalls
- **Buffer cache** (`vfs_bio.c`, `vfs_cluster.c`) — buffer I/O, clustering
- **VFS-VM integration** (`vfs_vm.c`) — VM/VFS interaction
- **Journaling** (`vfs_journal.c`, `vfs_jops.c`) — filesystem journaling support
- **Locking** (`vfs_lock.c`) — vnode locking
- **Helpers** (`vfs_helper.c`, `vfs_sync.c`, `vfs_synth.c`, `vfs_quota.c`) — VFS helper routines, sync, synthetic filesystems, quotas
- **AIO** (`vfs_aio.c`) — asynchronous I/O

### IPC and networking-adjacent
- **UIPC** (`uipc_*.c`, 11 files) — Unix IPC: sockets, mbufs, domains, protocols, accept filters, syscalls
- **System V IPC** (`sysv_*.c`, 4 files) — message queues, semaphores, shared memory
- **Pipes** (`sys_pipe.c`) — pipe implementation
- **Message queues** (`sys_mqueue.c`) — POSIX message queues

### Device and driver infrastructure
- **Device framework** (`kern_conf.c`, `kern_device.c`, `subr_autoconf.c`, `subr_bus.c`, `subr_devstat.c`, `subr_disk.c`) — device registration, bus/driver model, disk layer
- **Disk labels/partitions** (`subr_disklabel32.c`, `subr_disklabel64.c`, `subr_diskslice.c`, `subr_diskmbr.c`, `subr_diskgpt.c`, `subr_diskiocom.c`) — disk partitioning schemes
- **DMA** (`subr_busdma.c`) — bus DMA interfaces
- **Resource management** (`subr_rman.c`) — resource allocation framework
- **Firmware** (`subr_firmware.c`, `firmware/`) — firmware loading support

### System monitoring and debugging
- **Kernel tracing** (`kern_ktr.c`, `kern_ktrace.c`) — kernel trace buffer, ktrace syscall tracing
- **Debugging** (`kern_debug.c`) — kernel debugging support
- **sysctl** (`kern_sysctl.c`, `kern_mib.c`, `kern_posix4_mib.c`) — sysctl tree and standard MIBs
- **Accounting** (`kern_acct.c`) — process accounting
- **Sensors** (`kern_sensors.c`) — hardware sensor framework
- **Watchdog** (`kern_wdog.c`) — watchdog timer support
- **Statistics** (`subr_kcore.c`, `subr_prof.c`) — kernel core dumps, profiling

### Scheduling subsystems
- **Disk scheduling** (`kern_dsched.c`) — disk I/O scheduler framework
- **I/O scheduling** (`kern_iosched.c`) — general I/O scheduling
- **CPU scheduling policies** (`usched_bsd4.c`, `usched_dfly.c`, `usched_dummy.c`) — BSD4, DragonFly, and dummy user schedulers

### Security and capabilities
- **Capabilities** (`kern_caps.c`) — capability-based security
- **ACLs** (`kern_acl.c`) — access control lists
- **Jails** (`kern_jail.c`) — jail/container support

### TTY subsystem
- **TTY core** (`tty.c`, `tty_conf.c`, `tty_cons.c`, `tty_pty.c`, `tty_subr.c`, `tty_tty.c`) — terminal I/O, line disciplines, console, ptys

### System calls and linkage
- **System call infrastructure** (`syscalls.c`, `kern_syscalls.c`, `sys_generic.c`, `sys_socket.c`, `sys_process.c`) — syscall tables, generic syscalls, process control
- **Dynamic linking** (`kern_linker.c`, `link_elf.c`, `link_elf_obj.c`) — kernel module loading, ELF linking

### Utilities and support
- **Kernel subroutines** (`kern_subr.c`, `subr_param.c`, `subr_prf.c`, `subr_log.c`) — misc kernel utilities, printf, kernel log
- **CPU topology** (`subr_cpu_topology.c`, `subr_cpuhelper.c`) — CPU enumeration and helpers
- **Eventhandlers** (`subr_eventhandler.c`) — event notification framework
- **Task queues** (`subr_taskqueue.c`, `subr_gtaskqueue.c`) — deferred work queues
- **Random number generation** (`kern_nrandom.c`, `subr_csprng.c`) — random/CSPRNG
- **Checksums** (`md4c.c`, `md5c.c`) — MD4/MD5 implementations
- **Misc** (`kern_collect.c`, `kern_environment.c`, `kern_fp.c`, `kern_kinfo.c`, `kern_memio.c`, `kern_physio.c`, `kern_shutdown.c`, `kern_udev.c`, `kern_uuid.c`, `kern_varsym.c`, `kern_xio.c`, `subr_fattime.c`, `subr_kobj.c`, `subr_module.c`, `subr_power.c`, `subr_scanf.c`, `subr_unit.c`) — various utilities

### Message chain library
- **libmchain/** — subdirectory for message chaining utilities (used by some network protocols)

---

## Suggested reading phases

Given the large number of files (~180), we break them into dependency-ordered phases. Each phase focuses on a cohesive subsystem that can be understood mostly independently (after foundational phases).

### Phase 0: Understand DragonFly's threading model (LWKT) — **essential foundation**
**Goal:** Grasp how DragonFly's message-passing and token-based concurrency works, since it permeates all other subsystems.

Files:
- `lwkt_thread.c` — thread structure, creation, scheduling integration
- `lwkt_msgport.c` — message ports and message passing between threads
- `lwkt_token.c` — serializing tokens (DragonFly's primary locking primitive)
- `lwkt_ipiq.c` — inter-processor interrupt queues (cross-CPU messaging)
- `lwkt_serialize.c` — serialization helpers

Outcome: understanding of LWKT threads, tokens vs. traditional locks, message-passing model.

---

### Phase 1: Core synchronization and time
**Goal:** Understand basic locking primitives and timekeeping before diving into higher-level subsystems.

**1a. Synchronization primitives** (read after LWKT)
- `kern_spinlock.c` — spinlocks
- `kern_lock.c` — lockmgr locks
- `kern_mutex.c` — mutexes
- `kern_condvar.c` — condition variables
- `kern_umtx.c` — userland mutexes
- `kern_refcount.c` — reference counting
- `kern_sysref.c` — system reference counting
- `subr_sleepqueue.c` — sleep queues

**1b. Time and timers**
- `kern_clock.c` — system clock, hardclock, statclock
- `kern_cputimer.c` — per-CPU timer abstraction
- `kern_systimer.c` — system timers
- `kern_timeout.c` — callout/timeout mechanism
- `kern_time.c` — time-related syscalls
- `kern_ntptime.c` — NTP time adjustment

Outcome: fluency in DragonFly's locking and timing infrastructure.

---

### Phase 2: Memory allocation
**Goal:** Understand kernel memory management.

Files:
- `kern_kmalloc.c` — kernel malloc wrapper
- `kern_slaballoc.c` — slab allocator implementation
- `kern_objcache.c` — per-CPU object caches
- `kern_mpipe.c` — message pipe allocator (lock-free pools)
- `kern_sfbuf.c` — transient mappings (sf_buf)
- `subr_alist.c` — allocation lists
- `subr_blist.c` — bitmap-based block allocator
- `subr_rbtree.c` — red-black tree utilities
- `subr_sbuf.c` — string buffers
- `subr_sglist.c` — scatter-gather lists

Outcome: know how kernel allocates memory and manages temporary resources.

---

### Phase 3: Initialization and bootstrap
**Goal:** Understand how the kernel starts up.

Files:
- `init_main.c` — main kernel initialization path
- `init_sysent.c` — system call table initialization (generated)
- `subr_param.c` — kernel parameter computation
- `kern_environment.c` — kernel environment variables

Outcome: picture of the boot sequence and early setup.

---

### Phase 4: Process and thread management
**Goal:** Understand process/thread lifecycle.

**4a. Lifecycle**
- `kern_fork.c` — fork, rfork, vfork
- `kern_exec.c` — execve and exec machinery
- `kern_exit.c` — process exit, wait
- `kern_proc.c` — process structure management
- `kern_threads.c` — thread management
- `kern_kthread.c` — kernel threads
- `imgact_elf.c` — ELF image activator
- `imgact_shell.c` — shell script (#!) activator
- `imgact_resident.c` — resident image support

**4b. Resources and credentials**
- `kern_descrip.c` — file descriptor tables
- `kern_plimit.c` — process limits
- `kern_resource.c` — resource accounting (getrusage, etc.)
- `kern_prot.c` — credentials, uid/gid management

**4c. Signals**
- `kern_sig.c` — signal generation, delivery, handling

Outcome: comprehensive understanding of process/thread model, exec, fork, exit.

---

### Phase 5: Scheduling
**Goal:** Understand CPU scheduling policies and frameworks.

Files:
- `kern_sched.c` — generic scheduler framework
- `kern_synch.c` — sleep/wakeup, tsleep/wakeup
- `usched_bsd4.c` — BSD4 user scheduler
- `usched_dfly.c` — DragonFly user scheduler (message-based)
- `usched_dummy.c` — dummy scheduler
- `kern_usched.c` — user scheduler registration and switching

Outcome: understanding of how threads are scheduled on CPUs and how policies are pluggable.

---

### Phase 6: Virtual filesystem (VFS) core
**Goal:** Understand the VFS layer architecture.

**6a. VFS initialization and core**
- `vfs_init.c` — VFS subsystem init
- `vfs_conf.c` — filesystem type registration
- `vfs_subr.c` — vnode allocation, reference counting, core utilities
- `vfs_vfsops.c` — filesystem operations (mount, unmount, statfs, etc.)
- `vfs_vnops.c` — generic vnode operations
- `vfs_vopops.c` — vnode operation dispatch
- `vfs_default.c` — default vnode operation implementations

**6b. Name lookup and caching**
- `vfs_cache.c` — name cache
- `vfs_lookup.c` — traditional path lookup
- `vfs_nlookup.c` — new lookup mechanism

**6c. Mounting**
- `vfs_mount.c` — mount/unmount implementation
- `vfs_syscalls.c` — VFS-related system calls

**6d. Buffer cache and I/O**
- `vfs_bio.c` — buffer cache
- `vfs_cluster.c` — read/write clustering
- `vfs_vm.c` — VFS/VM integration

**6e. VFS extensions**
- `vfs_lock.c` — vnode locking
- `vfs_helper.c` — VFS helper utilities
- `vfs_sync.c` — filesystem sync support
- `vfs_synth.c` — synthetic filesystem support
- `vfs_journal.c` — journaling support
- `vfs_jops.c` — journal operations
- `vfs_quota.c` — quota support
- `vfs_aio.c` — asynchronous I/O

Outcome: solid grasp of VFS architecture, name lookup, buffer cache, mount/unmount flows.

---

### Phase 7: IPC and socket layer
**Goal:** Understand Unix IPC and socket infrastructure.

**7a. UIPC (Unix IPC)**
- `uipc_domain.c` — protocol domains
- `uipc_proto.c` — protocol switch
- `uipc_socket.c` — socket layer core
- `uipc_socket2.c` — additional socket operations
- `uipc_sockbuf.c` — socket buffer management
- `uipc_mbuf.c` — mbuf allocation and manipulation
- `uipc_mbuf2.c` — additional mbuf utilities
- `uipc_usrreq.c` — Unix domain sockets
- `uipc_syscalls.c` — socket system calls
- `uipc_msg.c` — message-based socket operations (DragonFly-specific)
- `uipc_accf.c` — accept filters

**7b. System V IPC**
- `sysv_ipc.c` — common SysV IPC code
- `sysv_msg.c` — message queues
- `sysv_sem.c` — semaphores
- `sysv_shm.c` — shared memory

**7c. Other IPC**
- `sys_pipe.c` — pipes
- `sys_mqueue.c` — POSIX message queues

Outcome: understanding of socket layer, mbuf management, Unix domain sockets, SysV IPC, pipes.

---

### Phase 8: Device and driver infrastructure
**Goal:** Understand device attachment, bus framework, and disk layer.

**8a. Device/bus framework**
- `kern_conf.c` — device switch tables (cdevsw, bdevsw)
- `kern_device.c` — device registration
- `subr_bus.c` — newbus device/driver model
- `subr_autoconf.c` — autoconfiguration
- `subr_busdma.c` — bus DMA framework
- `subr_rman.c` — resource manager

**8b. Disk layer**
- `subr_disk.c` — disk device layer
- `subr_devstat.c` — device statistics
- `subr_diskslice.c` — disk slicing (partitioning)
- `subr_disklabel32.c` — 32-bit disklabels
- `subr_disklabel64.c` — 64-bit disklabels
- `subr_diskmbr.c` — MBR partitions
- `subr_diskgpt.c` — GPT partitions
- `subr_diskiocom.c` — disk ioctl common code
- `kern_dsched.c` — disk scheduling framework
- `kern_iosched.c` — I/O scheduling

**8c. Firmware**
- `subr_firmware.c` — firmware loading
- `firmware/` subdirectory

Outcome: understanding of how devices are attached, how disk partitioning works, and I/O scheduling.

---

### Phase 9: System calls and kernel linkage
**Goal:** Understand syscall infrastructure and dynamic kernel linking.

**9a. System calls**
- `syscalls.c` — system call table (generated)
- `kern_syscalls.c` — syscall implementation helpers
- `sys_generic.c` — generic syscalls (read, write, ioctl, select, poll, etc.)
- `sys_socket.c` — socket syscalls (accept, bind, connect, etc.)
- `sys_process.c` — process control syscalls (ptrace, etc.)

**9b. Dynamic linking**
- `kern_linker.c` — kernel linker framework
- `link_elf.c` — ELF kernel module loader
- `link_elf_obj.c` — relocatable ELF object loader
- `kern_module.c` — module registration and management
- `subr_kobj.c` — kernel object interfaces
- `subr_module.c` — module utilities

Outcome: how syscalls are dispatched and how kernel modules are loaded/linked.

---

### Phase 10: Monitoring, debugging, and security
**Goal:** Understand observability and security features.

**10a. Tracing and debugging**
- `kern_ktr.c` — kernel trace buffer
- `kern_ktrace.c` — ktrace (syscall tracing)
- `kern_debug.c` — kernel debug support

**10b. sysctl and MIBs**
- `kern_sysctl.c` — sysctl implementation
- `kern_mib.c` — standard MIBs
- `kern_posix4_mib.c` — POSIX.4 MIBs
- `kern_kinfo.c` — kinfo structures (used by sysctl)

**10c. Accounting and sensors**
- `kern_acct.c` — process accounting
- `kern_sensors.c` — hardware sensor framework
- `kern_wdog.c` — watchdog timer

**10d. Security**
- `kern_caps.c` — capability-based security (DragonFly caps)
- `kern_acl.c` — ACLs
- `kern_jail.c` — jails

Outcome: visibility into kernel tracing, sysctl framework, sensors, and security mechanisms.

---

### Phase 11: TTY subsystem
**Goal:** Understand terminal I/O.

Files:
- `tty.c` — TTY core
- `tty_conf.c` — line discipline configuration
- `tty_cons.c` — console device
- `tty_pty.c` — pseudo-terminals
- `tty_subr.c` — TTY subroutines (clist management)
- `tty_tty.c` — controlling TTY device

Outcome: understanding of terminal I/O, line disciplines, and ptys.

---

### Phase 12: Utilities and miscellaneous
**Goal:** Catalog remaining support code.

Files (alphabetically by topic):
- **CPU topology:** `subr_cpu_topology.c`, `subr_cpuhelper.c`
- **Event handling:** `subr_eventhandler.c`
- **Task queues:** `subr_taskqueue.c`, `subr_gtaskqueue.c`
- **Random:** `kern_nrandom.c`, `subr_csprng.c`
- **Checksums:** `md4c.c`, `md5c.c`
- **Kernel subroutines:** `kern_subr.c`, `subr_prf.c` (printf), `subr_log.c` (kernel log)
- **Profiling:** `subr_prof.c`, `subr_kcore.c`
- **Power management:** `subr_power.c`
- **Parsing:** `subr_scanf.c`
- **Units:** `subr_unit.c` (unit number allocation)
- **Misc time:** `subr_fattime.c` (FAT timestamp conversion)
- **Misc kernel:** `kern_checkpoint.c`, `kern_collect.c`, `kern_dmsg.c` (distributed messaging), `kern_event.c` (kevent), `kern_fp.c` (floating point), `kern_memio.c`, `kern_physio.c`, `kern_shutdown.c`, `kern_udev.c`, `kern_uuid.c`, `kern_varsym.c` (variable symbols), `kern_xio.c` (extended I/O)
- **libmchain/** subdirectory

Outcome: familiarity with utility functions and miscellaneous subsystems.

---

## Documentation tasks (per phase)

For each phase:

1. **Subsystem overview**
   - Write a concise Markdown document in `sys/kern/` (e.g., `sys/kern/LWKT.md`, `sys/kern/VFS.md`) summarizing:
     - Purpose and role of the subsystem.
     - Key data structures and entry points.
     - How it interacts with other subsystems.
     - DragonFly-specific design choices (e.g., tokens vs. traditional locks, message-passing in LWKT).

2. **File-level notes** (for complex or pivotal files)
   - Add notes describing:
     - Main responsibility.
     - Important functions and structures.
     - Dependencies and callers.

3. **Cross-references**
   - Link to related subsystems (e.g., "VFS buffer cache interacts with VM pager, see `sys/vm/`").

All documentation must live in `~/s/dragonfly-docs/sys/kern/`, never in the source tree.

---

## Commit strategy

Following `AGENTS.md`:
- Commit incrementally after completing each phase's documentation.
- Each commit should be focused (e.g., "Document LWKT subsystem" or "Document VFS core and name lookup").
- Never bundle unrelated subsystems in one commit.

---

## Summary

This plan organizes `sys/kern/` into **12 phases** that can be tackled incrementally:

0. **LWKT** (DragonFly threading model) — **read first**
1. Core synchronization and time
2. Memory allocation
3. Initialization
4. Process and thread management
5. Scheduling
6. VFS layer
7. IPC and sockets
8. Device/driver infrastructure
9. System calls and kernel linkage
10. Monitoring, debugging, security
11. TTY subsystem
12. Utilities and miscellaneous

Each phase is mostly self-contained after earlier dependencies, allowing focused reading and documentation without overwhelming context.

---

## Progress Tracking

### Completed Phases

| Phase | Topic | Documentation | Lines | Commit |
|-------|-------|---------------|-------|--------|
| **0** | LWKT Threading | `lwkt.md` | 740 | ✅ |
| **1a** | Synchronization | `synchronization.md` | 915 | ✅ |
| **1b** | Time & Timers | `time.md` | 1,403 | ✅ |
| **2** | Memory Allocation | `memory.md` | 2,793 | ✅ |
| **3** | Initialization | `initialization.md` | 1,167 | ✅ |
| **4a** | Process Lifecycle | `processes.md` | 1,133 | ✅ |
| **4b** | Resources/Credentials | `resources.md` | 857 | ✅ |
| **4c** | Signals | `signals.md` | 1,018 | ✅ |
| **5** | Scheduling | `scheduling.md` | 923 | ✅ |
| **6a** | VFS Core | `vfs/index.md` | 722 | ✅ |
| **6b** | VFS Name Lookup | `vfs/namecache.md` | 837 | ✅ |
| **6c** | VFS Mounting | `vfs/mounting.md` | 1,181 | ✅ |
| **6d** | VFS Buffer Cache | `vfs/buffer-cache.md` | 1,666 | ✅ |
| **6e** | VFS Operations | `vfs/vfs-operations.md` | 847 | ✅ |
| **6e** | VFS Journaling | `vfs/journaling.md` | 1,214 | ✅ |
| **6e** | VFS Locking | `vfs/vfs-locking.md` | 569 | ✅ |
| **6e** | VFS Extensions | `vfs/vfs-extensions.md` | 627 | ✅ |
| **7a1** | Mbufs | `ipc/mbufs.md` | 801 | `16b4658` |
| **7a2** | Sockets | `ipc/sockets.md` | 1,098 | `10f10b0` |
| **7a3** | Unix Domain Sockets | `ipc/unix-sockets.md` | 812 | `c85db6f` |
| **7a4** | Protocol Dispatch | `ipc/protocol-dispatch.md` | 825 | `8d06674` |
| **7c1** | Pipes | `ipc/pipes.md` | 510 | `4473f57` |
| **7c2** | POSIX Message Queues | `ipc/mqueue.md` | 368 | `5fae267` |
| **7b1** | SysV Message Queues | `ipc/sysv-msg.md` | 312 | `0de9e53` |
| **7b2** | SysV Semaphores | `ipc/sysv-sem.md` | 345 | `88f6aae` |
| **7b3** | SysV Shared Memory | `ipc/sysv-shm.md` | 340 | `3d4525b` |
| **8a** | Devices & Drivers | `devices.md` | 877 | ✅ |
| **8a** | NewBus Framework | `newbus.md` | 783 | ✅ |
| **8a** | Bus Resources & DMA | `bus-resources.md` | 547 | ✅ |
| **8b** | Disk Subsystem | `disk.md` | 988 | ✅ |
| **8d** | Firmware Loading | `firmware.md` | 347 | ✅ |
| **9a** | System Calls | `syscalls.md` | 485 | `87b914f` |
| **9b** | Kernel Linker (KLD) | `kld.md` | 675 | `52027b4` |
| **10a** | Tracing & Debugging | `tracing.md` | 534 | `d7c0a1c` |
| **10b** | Sysctl Framework | `sysctl.md` | 656 | `571d0b6` |
| **10c** | Accounting & Sensors | `accounting.md` | 624 | `5535505` |
| **10d** | Security | `security.md` | 615 | `8a6bc2a` |
| **11a** | TTY Subsystem | `tty.md` | 1,092 | `9e00ccf` |
| **11b** | Pseudo-Terminals | `tty-pty.md` | 1,078 | `5d3204e` |

**Total completed:** ~32,700+ lines of documentation

### Pending Phases

| Phase | Topic | Status |
|-------|-------|--------|
| **12** | Utilities & Miscellaneous | Pending |

---

## Phase 8 Detailed Plan: Device & Driver Infrastructure

### Overview

Phase 8 covers **~10,500 lines** across **17 source files** in four subphases:

| Subphase | Files | Lines | Description |
|----------|-------|-------|-------------|
| **8a** | 6 files | ~6,377 | Device/Bus Framework (NewBus, dev_ops, rman) |
| **8b** | 8 files | ~4,499 | Disk Layer (partitioning, labels, MBR/GPT) |
| **8c** | 2 files | ~251 | I/O Scheduling (stubs + write throttling) |
| **8d** | 1 file | ~540 | Firmware Loading |

### Source Files

#### 8a: Device/Bus Framework (~6,377 lines)

| File | Lines | Purpose |
|------|-------|---------|
| `kern_conf.c` | 514 | Device number primitives, `make_dev()`/`destroy_dev()`, devfs integration |
| `kern_device.c` | 791 | Device operations dispatch (`dev_d*`), MPSAFE handling, default handlers |
| `subr_bus.c` | 3,991 | **NewBus core** - devclass, device/driver model, /dev/devctl, resources |
| `subr_autoconf.c` | 202 | Interrupt-driven configuration hooks |
| `subr_busdma.c` | 144 | Bus DMA helper functions |
| `subr_rman.c` | 735 | Resource manager (I/O ports, memory, IRQs) |

#### 8b: Disk Layer (~4,499 lines)

| File | Lines | Purpose |
|------|-------|---------|
| `subr_disk.c` | 1,601 | **Core disk layer** - creation, probing, slice management, BIO dispatch |
| `subr_devstat.c` | 315 | Device I/O statistics (for `iostat`) |
| `subr_diskslice.c` | 907 | Disk slicing framework, ioctl handlers |
| `subr_disklabel32.c` | 662 | Traditional BSD 32-bit disklabels |
| `subr_disklabel64.c` | 544 | **DragonFly 64-bit disklabels** (native format) |
| `subr_diskmbr.c` | 556 | MBR partition table parsing |
| `subr_diskgpt.c` | 244 | GPT partition table parsing |
| `subr_diskiocom.c` | 670 | Disk dmsg protocol (clustered storage) |

#### 8c: I/O Scheduling (~251 lines)

| File | Lines | Status | Purpose |
|------|-------|--------|---------|
| `kern_dsched.c` | 81 | **STUB** | Disk scheduling framework (empty implementations) |
| `kern_iosched.c` | 170 | Active | Write throttling for I/O fairness |

#### 8d: Firmware (~540 lines)

| File | Lines | Purpose |
|------|-------|---------|
| `subr_firmware.c` | 540 | Firmware image registry and loading |

### Key Data Structures

#### Device/Bus Framework
- `struct dev_ops` - Character device switch table
- `struct bsd_device` - NewBus device instance
- `struct devclass` - Device class container
- `struct resource` / `struct rman` - Resource management
- `cdev_t` - Device pointer (opaque)

#### Disk Layer
- `struct disk` - Main disk descriptor
- `struct diskslices` / `struct diskslice` - Slice management
- `struct disklabel32` / `struct disklabel64` - Disk labels
- `struct devstat` - Per-device statistics

### DragonFly-Specific Highlights

1. **Message-Based Disk Operations** - LWKT messages for async disk management
2. **64-bit Disklabel Format** - Native support for >2TB disks with byte-based addressing
3. **Dual Label Support** - Runtime selection between 32-bit and 64-bit disklabels
4. **Async Device Attachment** - Threaded probing for faster boot (`DF_ASYNCPROBE`)
5. **MPSAFE Device Operations** - Per-device MPSAFE flags, BKL only when needed
6. **KVABIO Support** - Buffer synchronization for non-KVABIO devices
7. **Read Prioritization** - `bioqdisksort()` prioritizes reads with write trickle
8. **dmsg Protocol** - Distributed block device access for clustering
9. **Device Aliases** - Stable naming via serial number, UUID, pack label

### Proposed Documentation Structure

```
docs/sys/kern/
├── devices.md              # Device framework (dev_ops, make_dev, NewBus)
├── disk.md                 # Disk layer (slices, labels, MBR/GPT, stats)
├── resources.md            # (exists) - may add rman details
└── firmware.md             # Firmware loading subsystem
```

### Estimated Documentation Sizes

| Document | Est. Lines | Content |
|----------|------------|---------|
| `devices.md` | 800-1000 | dev_ops, make_dev, NewBus, devclass, bus methods |
| `disk.md` | 600-800 | Disk layer, slices, labels, MBR/GPT, I/O sched |
| `firmware.md` | 250-350 | Firmware registry, loading |
| **Total** | **1650-2150** | |

### Execution Order

1. **devices.md** - Foundation for understanding disk and driver attachment
2. **disk.md** - Core disk layer (depends on device framework)
3. **firmware.md** - Independent, can be done in any order

### Notes

- `kern_dsched.c` is entirely stubs - will be documented as placeholder/historical
- `subr_diskiocom.c` (dmsg) will get brief coverage; full clustering docs are out of scope
- The existing `resources.md` covers process resources; rman is different (hardware resources)
