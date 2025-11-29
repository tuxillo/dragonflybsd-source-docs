# DragonFly BSD Kernel Documentation

Welcome to the comprehensive documentation for the DragonFly BSD kernel source code.

## About This Documentation

This documentation project aims to provide clear, accessible explanations of the DragonFly BSD kernel's internals, making it easier for developers, researchers, and enthusiasts to understand how this sophisticated operating system works.

## What is DragonFly BSD?

DragonFly BSD is a fork of FreeBSD designed with a focus on:

- **Multiprocessor scalability** — Efficient performance on multi-core systems
- **Message-passing architecture** — LWKT (Lightweight Kernel Threading) for lock-free concurrency
- **Advanced filesystems** — HAMMER and HAMMER2 with clustering capabilities
- **Innovation** — Modern kernel design patterns while maintaining UNIX heritage

## Documentation Organization

The documentation is organized to mirror the kernel source tree structure, making it easy to find information about specific subsystems:

### [Kernel Core (`sys/kern/`)](sys/kern/index.md)

The heart of the kernel, containing:

- **LWKT Threading** — DragonFly's unique message-passing concurrency model
- **Process & Thread Management** — How processes and threads are created, scheduled, and managed
- **Virtual Filesystem (VFS)** — The abstraction layer for filesystems
- **IPC & Sockets** — Inter-process communication and networking foundations
- **Memory Management** — Kernel memory allocation and management
- **Device Framework** — How devices and drivers integrate with the kernel

### [Virtual Memory (`sys/vm/`)](sys/vm/index.md)

The virtual memory subsystem managing:

- VM objects and pages
- Paging and swap
- Memory mapping
- Page cache

### [CPU Architecture (`sys/cpu/x86_64/`)](sys/cpu/x86_64/index.md)

Machine-dependent code for x86-64:

- Low-level CPU interfaces
- MMU management
- Trap handling
- Assembly routines

## How to Use This Documentation

1. **Start with the basics** — If you're new to DragonFly, begin with [Getting Started](getting-started.md)
2. **Explore by subsystem** — Navigate through the [Kernel Subsystems](sys/index.md) section
3. **Follow the architecture** — Documentation mirrors the source tree for easy cross-referencing
4. **Deep dive** — Each subsystem page provides overviews, key concepts, and code flows

## Contributing

This documentation is a living project. If you find areas that need clarification or expansion, contributions are welcome.

## Getting Started

Ready to dive in? Check out the [Getting Started](getting-started.md) guide to learn how to navigate this documentation and understand DragonFly's unique architecture.
