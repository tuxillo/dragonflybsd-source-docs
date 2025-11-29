# `sys/` Reading and Documentation Plan

This plan describes how to read and then document the DragonFly BSD `sys/` subtree incrementally, while mirroring the layout from `~/s/dragonfly` into this documentation repository `~/s/dragonfly-docs`.

## Scope and structure

Current top-level entries under `sys/` in the source tree include:

- `compile/` — kernel configuration build trees and generated objects.
- `config/` — kernel configuration files and build descriptions.
- `cpu/` — architecture-specific code; currently `x86_64/` with:
  - `include/` — low-level machine headers (CPU, MMU, traps, types, etc.).
  - `misc/` — assorted machine-dependent code (assembly stubs, debugger helpers, ELF glue).
- `ddb/` — in-kernel debugger support.
- `libiconv/` — character set conversion library used in the system (iconv core and converters).
- `libkern/` — common kernel utility functions (C library–style primitives used in the kernel).
- `libprop/` — property list / proplib library used by kernel and userland.
- `net/` — core networking layer (interfaces, routing, netisr, generic infrastructure).
- `netbt/` — Bluetooth stack (HCI, L2CAP, RFCOMM, SCO).
- `netinet6/` — IPv6 networking stack (protocols, routing, neighbor discovery, raw sockets, etc.).
- `netproto/` — protocol-specific support code (for example, 802.11).
- `opencrypto/` — cryptographic framework and software crypto providers.
- `vm/` — virtual memory subsystem (VM objects, pages, mappings, pagers).
- `Makefile.modules` — top-level makefile for building kernel modules.

Documentation for each of these must live under the matching path in this repo, for example:

- Source: `~/s/dragonfly/sys/netinet6` → Docs: `~/s/dragonfly-docs/sys/netinet6/`
- Source: `~/s/dragonfly/sys/cpu/x86_64/include` → Docs: `~/s/dragonfly-docs/sys/cpu/x86_64/include/`

Any additional subdirectories discovered later should follow the same mirroring rule.

## Incremental reading order

1. **`libiconv/` (self-contained library)**
   - Goal: understand the iconv front-end (`iconv.c`) and how converters are registered and invoked.
   - Skim: `Makefile`, public entry points, and interfaces (`iconv_converter_if.m`).
   - Deep dive: conversion implementations (`iconv_ucs.c`, `iconv_xlat*.c`) to see common patterns.
   - Outcome: ability to describe how character set conversion is integrated and extended.

2. **`netinet6/` (IPv6 networking stack)**
   - Goal: map the major IPv6 components and data flows.
   - Skim first:
     - Core IPv6 headers and main code paths (`ip6.h`, `ip6_input.c`, `ip6_output.c`, `ip6_forward.c`).
     - Protocol control blocks and routing (`in6.c`, `in6_pcb.c`, `in6_rmx.c`, `route6.c`).
   - Second pass:
     - Neighbor discovery and router / prefix handling (`nd6*.c`, `mld6.c`, `scope6*.c`).
     - Raw and multicast handling (`raw_ip6.c`, `ip6_mroute*.c`, `udp6_*.c`, `tcp6_var.h`).
   - Outcome: high-level overview of the IPv6 stack, including packet path, control structures, and extension points.

3. **`cpu/x86_64/` (machine-dependent core)**
   - Goal: understand the machine-dependent interfaces and how they surface to the rest of the kernel.
   - First pass on `include/`:
     - Fundamental types and limits (`types.h`, `int_*`, `wchar*`, `limits.h`).
     - CPU and MMU interfaces (`cpu.h`, `cpufunc.h`, `cpumask.h`, `pmap.h`, `specialreg.h`).
     - Trap and context structures (`trap.h`, `frame.h`, `psl.h`, `reg.h`, `ucontext.h`, `sigframe.h`).
   - Second pass on `misc/`:
     - Assembly support files and stubs (`bzeront.s`, `monitor.s`).
     - Debugging and ELF glue (`db_disasm.c`, `elf_machdep.c`, `x86_64-gdbstub.c`).
   - Outcome: clear picture of which machine-dependent primitives higher-level kernel code relies on.

## Documentation tasks (per directory)

For each `sys/` subdirectory we read, follow the same documentation steps in the mirrored docs tree:

1. **Directory overview** (one concise Markdown file per major directory)
   - Explain the purpose of the directory and its role in the kernel.
   - List key entry points, data structures, and common control flows.

2. **File-level notes where helpful**
   - For complex or central files, add short notes describing:
     - Their primary responsibility.
     - Important structures and functions.
     - How they interact with other parts of `sys/`.

3. **Cross-linking between subsystems**
   - When documenting a directory, record its key dependencies on other `sys/` areas (for example, how `netinet6/` depends on machine-dependent headers, or on common networking code once those directories are added).

All documentation produced must be written under `~/s/dragonfly-docs`, never in the source tree.

## Suggested work sequence

- Phase 1: `libiconv/`
  - [ ] Skim overall layout and key entry points.
  - [ ] Draft `sys/libiconv/` overview doc.

- Phase 2: `netinet6/`
  - [ ] Map main data paths (input/output/forwarding).
  - [ ] Map control structures (PCBs, routing, neighbor discovery).
  - [ ] Draft `sys/netinet6/` overview doc and selected file notes.

- Phase 3: `cpu/x86_64/`
  - [ ] Survey `include/` headers and categorize interfaces.
  - [ ] Review `misc` implementations for those interfaces.
  - [ ] Draft `sys/cpu/x86_64/` overview doc and notes for critical headers.

- Later phases / backlog (to be scheduled)
  - `compile/`, `config/` — configuration and build plumbing.
  - `ddb/` — in-kernel debugger.
  - `libkern/`, `libprop/` — shared kernel / property list libraries.
  - `net/`, `netbt/`, `netproto/` — non-IPv6 networking layers.
  - `opencrypto/` — crypto framework and software providers.
  - `vm/` — VM subsystem details beyond dependencies needed earlier.

This plan can be extended as additional `sys/` subdirectories appear or are brought into scope; each new directory should be slotted into a similar "read, then document" sequence and mirrored under `~/s/dragonfly-docs/sys/`.