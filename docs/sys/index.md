# Kernel Subsystems Overview

The DragonFly BSD kernel (`sys/`) is organized into subsystems that handle different aspects of the operating system. This page provides a high-level overview of the major components.

## Core Kernel (`kern/`)

The **kernel core** is the heart of DragonFly, containing fundamental subsystems:

- **[LWKT Threading](kern/lwkt.md)** — Message-passing based threading model unique to DragonFly
- **[Synchronization](kern/synchronization.md)** — Tokens, locks, and synchronization primitives
- **[Memory Management](kern/memory.md)** — Kernel memory allocation (malloc, slab allocator, object caches)
- **[Processes & Threads](kern/processes.md)** — Process lifecycle (fork, exec, exit) and thread management
- **[Scheduling](kern/scheduling.md)** — CPU scheduling framework and policies
- **[Virtual Filesystem (VFS)](kern/vfs/index.md)** — Filesystem abstraction layer
- **[IPC & Sockets](kern/ipc.md)** — Inter-process communication and socket layer
- **[Devices & Drivers](kern/devices.md)** — Device framework and driver infrastructure
- **[System Calls](kern/syscalls.md)** — System call infrastructure and implementation

[Explore kern/ in detail →](kern/index.md)

## Virtual Memory (`vm/`)

The **virtual memory subsystem** manages memory at the page level:

- VM objects and shadow objects
- Physical page management
- Paging and page replacement
- Swap management
- Memory mapping (`mmap`)
- Buffer cache integration

[Explore vm/ in detail →](vm/index.md)

## CPU Architecture (`cpu/x86_64/`)

**Machine-dependent code** for the x86-64 architecture:

- CPU initialization and control
- MMU and page table management
- Trap and interrupt handling
- Context switching
- Assembly routines
- Low-level primitives

[Explore cpu/x86_64/ in detail →](cpu/x86_64/index.md)

## Networking

### Core Networking (`net/`)

Generic networking infrastructure:

- Network interfaces (`struct ifnet`)
- Routing tables
- Network message passing (`netisr`)
- BPF (Berkeley Packet Filter)

### IPv6 (`netinet6/`)

IPv6 protocol stack:

- IPv6 packet processing
- Neighbor discovery
- Routing and forwarding
- ICMPv6
- Multicast support

### Bluetooth (`netbt/`)

Bluetooth protocol stack:

- HCI (Host Controller Interface)
- L2CAP (Logical Link Control and Adaptation Protocol)
- RFCOMM
- SCO (Synchronous Connection-Oriented)

## Storage and Filesystems

### Device I/O

- Disk layer and partitioning
- Device statistics
- I/O scheduling
- DMA support

### VFS Layer

See [kern/vfs/](kern/vfs/index.md) for the filesystem abstraction layer.

## Security

- **Capabilities** — Capability-based security model
- **ACLs** — Access control lists
- **Jails** — Container-like isolation

## Debugging and Monitoring

- **DDB** — In-kernel debugger
- **KTR** — Kernel trace buffer
- **ktrace** — System call tracing
- **sysctl** — Runtime configuration and monitoring

## Libraries

### Kernel Libraries

- **libkern** — C library functions for kernel use
- **libiconv** — Character set conversion
- **libprop** — Property lists (kernel/userland shared)

### Cryptography

- **opencrypto** — Cryptographic framework
- Software crypto implementations
- Hardware crypto driver support

## Kernel Configuration

- **config/** — Kernel configuration files
- **compile/** — Build output directories

## Key Architectural Principles

### Message Passing Over Locking

DragonFly minimizes traditional locking by using:

- Message-based IPC between threads
- Tokens for serialization when needed
- Per-CPU data structures to avoid contention

### Scalability Focus

Design choices emphasize multiprocessor performance:

- Lock-free algorithms where possible
- Cache-friendly data structures
- Minimal serialization points

### Cache Coherency

DragonFly's HAMMER filesystem and buffer cache leverage:

- Distributed caching
- Cluster-aware design
- Cache coherency protocols

## Next Steps

- Start with [kern/](kern/index.md) to explore the kernel core
- Learn about [LWKT Threading](kern/lwkt.md) to understand DragonFly's unique approach
- Dive into specific subsystems based on your interests

## Subsystem Dependencies

Understanding dependencies helps navigate the kernel:

```
LWKT Threading (foundational)
    ↓
Synchronization Primitives
    ↓
Memory Management
    ↓
Process Management → VFS → Filesystems
    ↓              ↓
Scheduling    Device I/O
```

Start with LWKT to understand the foundation, then explore other subsystems.
