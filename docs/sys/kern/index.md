# Kernel Core (`kern/`) Overview

The `sys/kern/` directory contains the core kernel subsystems — the fundamental building blocks of the DragonFly BSD operating system. With approximately 180 source files, `kern/` implements everything from threading and process management to filesystems and device drivers.

## What Makes DragonFly Unique

Before diving into specifics, understand that DragonFly's kernel core differs significantly from traditional BSD kernels:

### LWKT: The Foundation

**Lightweight Kernel Threading (LWKT)** is DragonFly's message-passing based concurrency model. Instead of pervasive locking, DragonFly uses:

- **Message ports** attached to threads
- **Tokens** for serialization (can be held across blocking operations)
- **Cross-CPU message passing** via IPIQs (Inter-Processor Interrupt Queues)

This architecture reduces lock contention and enables better scalability on multi-core systems.

**Start here:** [LWKT Threading](lwkt.md) is essential to understand before exploring other subsystems.

## Major Subsystems

### Core Infrastructure

#### [LWKT Threading](lwkt.md)
DragonFly's message-passing threading model — the architectural foundation.

- `lwkt_thread.c` — Thread management
- `lwkt_msgport.c` — Message ports and message passing
- `lwkt_token.c` — Serializing tokens
- `lwkt_ipiq.c` — Inter-processor interrupt queues
- `lwkt_serialize.c` — Serialization helpers

#### [Synchronization](synchronization.md)
Locks, tokens, and synchronization primitives.

- Spinlocks, mutexes, condition variables
- Token-based serialization
- Sleep queues
- Reference counting

#### [Memory Management](memory.md)
Kernel memory allocation and management.

- `kern_kmalloc.c` — Kernel malloc wrapper
- `kern_slaballoc.c` — Slab allocator
- `kern_objcache.c` — Per-CPU object caches
- `kern_mpipe.c` — Lock-free message pipe allocator

### Process and Thread Management

#### [Processes & Threads](processes.md)
Process lifecycle and thread management.

- `kern_fork.c` — Process creation (fork, rfork)
- `kern_exec.c` — Program execution (execve)
- `kern_exit.c` — Process termination and wait
- `kern_proc.c` — Process structure management
- `kern_threads.c` — Thread management
- `kern_sig.c` — Signal handling

#### [Scheduling](scheduling.md)
CPU scheduling framework and policies.

- `kern_sched.c` — Generic scheduler framework
- `usched_dfly.c` — DragonFly's message-based scheduler
- `usched_bsd4.c` — Traditional BSD4 scheduler
- `kern_synch.c` — Sleep/wakeup primitives

### Storage and Filesystems

#### [Virtual Filesystem (VFS)](vfs/index.md)
Filesystem abstraction layer.

- VFS core (`vfs_*.c`, 23 files)
- Name lookup and caching
- Buffer cache and I/O clustering
- Mount/unmount operations
- Journaling support
- VFS/VM integration

### Communication

#### [IPC & Sockets](ipc.md)
Inter-process communication and networking foundation.

- Unix domain sockets (`uipc_*.c`, 11 files)
- Mbuf management
- Socket layer
- System V IPC (messages, semaphores, shared memory)
- Pipes and POSIX message queues

### Hardware Interface

#### [Devices & Drivers](devices.md)
Device framework and driver infrastructure.

- Device registration and management
- Bus/driver model (newbus)
- Disk layer and partitioning
- DMA framework
- I/O scheduling

#### [System Calls](syscalls.md)
System call infrastructure and kernel module loading.

- System call dispatch
- Dynamic kernel linking
- Module management

## Subsystem Organization

The ~180 files in `kern/` cluster by prefix:

- `kern_*` (70 files) — Core kernel services
- `subr_*` (36 files) — Kernel subroutines and utilities
- `vfs_*` (23 files) — Virtual filesystem
- `uipc_*` (11 files) — Unix IPC
- `lwkt_*` (5 files) — Lightweight kernel threading
- `sys_*` (5 files) — System call implementations
- `tty_*` (5 files) — Terminal I/O
- `usched_*` (3 files) — User schedulers
- Plus image activators, dynamic linkers, and utilities

## Reading Order

If you're new to DragonFly's kernel core:

1. **[LWKT Threading](lwkt.md)** ← Start here! Essential foundation
2. **[Synchronization](synchronization.md)** — Tokens, locks, message passing
3. **[Memory Management](memory.md)** — Kernel allocation
4. **[Processes & Threads](processes.md)** — Process lifecycle
5. **[Scheduling](scheduling.md)** — CPU scheduling
6. **[VFS](vfs/index.md)** — Filesystem layer
7. **[IPC & Sockets](ipc.md)** — Communication
8. **[Devices](devices.md)** — Device framework
9. **[System Calls](syscalls.md)** — Syscall infrastructure

## Key Concepts

### Message Passing

Instead of calling functions directly across threads, DragonFly often uses **asynchronous messages**:

```
Thread A                    Thread B
   |                           |
   |-- send message ---------->|
   |                           | process message
   |<-- reply message ---------|
   |                           |
```

This reduces lock contention and cache coherency traffic.

### Tokens vs. Locks

**Tokens** can be held across blocking operations:

```c
lwkt_gettoken(&mp->mnt_token);
/* Can sleep here - token is retained */
lwkt_reltoken(&mp->mnt_token);
```

Traditional locks typically cannot be held across sleeps.

### Per-CPU Data

Many data structures are per-CPU to avoid cache-line bouncing:

```c
struct globaldata *gd = mycpu;
/* Access CPU-local data without locks */
```

## Dependencies

Understanding dependencies helps navigate `kern/`:

```
LWKT (foundation)
  ↓
Synchronization
  ↓
Memory allocation
  ↓
Processes/Threads → VFS → Filesystems
  ↓                 ↓
Scheduling      Device I/O
```

## Source Location

All source discussed here lives in:

```
~/s/dragonfly/sys/kern/
```

With documentation mirrored at:

```
~/s/dragonfly-docs/docs/sys/kern/
```

## What's Next?

Ready to dive deeper? Start with [LWKT Threading](lwkt.md) to understand DragonFly's unique concurrency model, then explore other subsystems based on your interests.

For a detailed reading plan covering all ~180 files, see the planning document at `planning/sys/kern/PLAN.md`.
