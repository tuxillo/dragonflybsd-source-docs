# Getting Started

This guide will help you navigate the DragonFly BSD kernel documentation and understand the unique aspects of DragonFly's architecture.

## Prerequisites

To get the most out of this documentation, you should have:

- **C programming experience** — The kernel is written in C
- **Basic OS concepts** — Understanding of processes, memory management, and I/O
- **UNIX/BSD familiarity** — Knowledge of UNIX system architecture is helpful

## Understanding DragonFly's Unique Architecture

DragonFly BSD differs from traditional BSD systems in several key ways:

### LWKT: Lightweight Kernel Threading

The most distinctive feature of DragonFly is its **message-passing** concurrency model:

- Traditional kernels use **locks** to protect shared data
- DragonFly uses **message passing** and **tokens** for most synchronization
- Reduces lock contention and improves multiprocessor scalability
- Start with the [LWKT Threading](sys/kern/lwkt.md) documentation to understand this foundational concept

### Token-Based Synchronization

Instead of traditional mutexes and read-write locks for most operations, DragonFly uses:

- **Tokens** — Serializing tokens that can be held across blocking operations
- **Message ports** — Each thread has message ports for asynchronous communication
- **IPIQs** — Inter-Processor Interrupt Queues for cross-CPU messaging

See [Synchronization](sys/kern/synchronization.md) for details.

## Documentation Structure

### Mirror of Source Tree

The documentation mirrors the kernel source tree at `~/s/dragonfly/sys/`:

```
Source: ~/s/dragonfly/sys/kern/kern_proc.c
  Docs: docs/sys/kern/processes.md

Source: ~/s/dragonfly/sys/vm/vm_page.c
  Docs: docs/sys/vm/index.md
```

This makes it easy to:

- Find documentation for specific source directories
- Cross-reference between code and docs
- Navigate familiar territory if you know the source layout

### Documentation Pages

Each subsystem documentation page follows a consistent structure:

1. **Overview** — What the subsystem does and why
2. **Key Concepts** — Important ideas and terminology
3. **Data Structures** — Core structures and their roles
4. **Key Functions** — Important entry points and operations
5. **Subsystem Interactions** — How it connects to other parts
6. **Code Flow Examples** — Walkthrough of typical operations
7. **Files** — Relevant source files
8. **References** — Links to related topics

## Recommended Reading Order

### For First-Time Readers

1. **[LWKT Threading](sys/kern/lwkt.md)** — Understand DragonFly's concurrency model first
2. **[Synchronization](sys/kern/synchronization.md)** — Learn about tokens, locks, and message passing
3. **[Processes & Threads](sys/kern/processes.md)** — How processes and threads work
4. **[Virtual Filesystem](sys/kern/vfs/index.md)** — VFS layer and file operations
5. **[Memory Management](sys/kern/memory.md)** — Kernel memory allocation

### For Specific Interests

- **Filesystem developers** → Start with [VFS](sys/kern/vfs/index.md)
- **Network programmers** → Begin with [IPC & Sockets](sys/kern/ipc.md)
- **Driver developers** → Check out [Devices & Drivers](sys/kern/devices.md)
- **Scheduler hackers** → Head to [Scheduling](sys/kern/scheduling.md)
- **Architecture enthusiasts** → Explore [CPU/x86_64](sys/cpu/x86_64/index.md)

## Code References

Throughout the documentation, you'll see references like:

- `kern_proc.c:142` — File and line number
- `fork1()` — Function name
- `struct proc` — Data structure

These help you locate the relevant source code in `~/s/dragonfly/sys/`.

## Understanding the Planning Documents

The repository also contains planning documents (in `planning/` directory) that outline:

- Reading order for source code
- Phases for documentation development
- Subsystem categorization

These are primarily for documentation maintainers but can be useful if you want to understand how the source tree is organized.

## Viewing the Documentation

This documentation is built with MkDocs and can be:

- **Viewed locally:** Run `make serve` in the repository root
- **Built as static HTML:** Run `make build` to generate `site/` directory
- **Read as Markdown:** All `.md` files in `docs/` are readable as plain text

## What's Next?

Now that you understand how the documentation is organized, you're ready to explore:

- [Kernel Subsystems Overview](sys/index.md) — High-level view of all subsystems
- [kern/ Overview](sys/kern/index.md) — Start with the kernel core
- [LWKT Threading](sys/kern/lwkt.md) — Dive into DragonFly's unique concurrency model

Happy exploring!
