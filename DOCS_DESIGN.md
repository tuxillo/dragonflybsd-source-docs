# Documentation Design and Structure

This document outlines the design, tooling, and structure for generating publishable documentation from this repository.

## Goals

1. **Readable documentation** — Clear, navigable documentation that helps developers understand the DragonFly BSD kernel.
2. **Automated generation** — Use a static site generator to transform Markdown files into a browsable website.
3. **Maintainable structure** — Organize documentation in a way that mirrors the source code while being easy to navigate.
4. **Version control friendly** — Keep documentation in plain Markdown files suitable for git workflows.

## Documentation Generator Options

### Option 1: MkDocs (Recommended)

**Pros:**
- Python-based, simple to install (`pip install mkdocs`)
- Excellent built-in search
- Clean, responsive themes (Material for MkDocs is outstanding)
- Simple YAML configuration
- Automatic navigation generation from file structure
- Fast build times
- Great support for code syntax highlighting
- Well-maintained and widely used

**Cons:**
- Requires Python environment
- Less flexible than some alternatives for complex customization

**Best for:** Technical documentation, API docs, kernel documentation (our use case)

**Example setup:**
```bash
pip install mkdocs mkdocs-material
mkdocs new .
mkdocs serve  # Local preview
mkdocs build  # Generate static HTML
```

### Option 2: Docusaurus

**Pros:**
- React-based, modern UI
- Excellent versioning support (good for tracking kernel versions)
- Built-in blog functionality
- Strong community and Facebook backing
- Plugin ecosystem

**Cons:**
- Requires Node.js/npm ecosystem
- More complex setup than MkDocs
- Heavier build process
- Overkill for pure documentation (more suited for project websites)

**Best for:** Full project websites with docs, blog, and community features

### Option 3: Sphinx

**Pros:**
- Industry standard for Python projects
- Very powerful and extensible
- ReStructuredText or Markdown support
- Excellent cross-referencing
- Can generate PDF, ePub, etc.

**Cons:**
- Steeper learning curve
- ReStructuredText syntax is more complex than Markdown
- Slower build times for large projects
- Setup is more involved

**Best for:** Large projects needing extensive cross-referencing, multiple output formats

### Option 4: Zola

**Pros:**
- Single binary, no dependencies (Rust-based)
- Very fast builds
- Simple setup
- Good theme support

**Cons:**
- Smaller community than MkDocs/Sphinx
- Less suited for pure documentation (more general-purpose)
- Fewer documentation-specific features

**Best for:** General static sites, blogs

### Option 5: mdBook

**Pros:**
- Rust-based, single binary
- Designed specifically for books/documentation
- Very fast
- Simple Markdown-only approach

**Cons:**
- Less sophisticated navigation than MkDocs
- Smaller plugin ecosystem
- Less flexible theming

**Best for:** Book-style documentation (sequential reading)

## Recommended Choice: MkDocs with Material Theme

**Rationale:**
- Perfect balance of simplicity and features for kernel documentation
- Excellent search and navigation capabilities
- Material theme provides outstanding UX for technical docs
- Easy to maintain and extend
- Fast iteration during documentation writing

## Documentation Structure

### Current Structure
```
dragonfly-docs/
├── AGENTS.md           # Agent guidelines
├── README.md           # Repository overview
├── DOCS_DESIGN.md      # This file
└── sys/
    ├── PLAN.md         # sys/ reading plan
    └── kern/
        └── PLAN.md     # kern/ reading plan (12 phases)
```

### Proposed Structure

```
dragonfly-docs/
├── mkdocs.yml                  # MkDocs configuration
├── AGENTS.md                   # Agent guidelines (repo internal)
├── README.md                   # Repository README
├── DOCS_DESIGN.md              # This design doc (repo internal)
│
├── docs/                       # Documentation root (MkDocs source)
│   ├── index.md               # Landing page
│   ├── getting-started.md     # How to read/use these docs
│   │
│   └── sys/                   # Mirrors source sys/
│       ├── index.md           # sys/ overview
│       │
│       ├── kern/              # Kernel core documentation
│       │   ├── index.md       # kern/ overview
│       │   ├── lwkt.md        # LWKT subsystem
│       │   ├── synchronization.md
│       │   ├── memory.md
│       │   ├── processes.md
│       │   ├── scheduling.md
│       │   ├── vfs/           # VFS subdirectory (if needed)
│       │   │   ├── index.md
│       │   │   ├── cache.md
│       │   │   ├── vnodes.md
│       │   │   └── buffer-cache.md
│       │   ├── ipc.md
│       │   ├── devices.md
│       │   └── syscalls.md
│       │
│       ├── vm/                # VM subsystem
│       │   ├── index.md
│       │   ├── paging.md
│       │   ├── objects.md
│       │   └── swap.md
│       │
│       ├── cpu/               # Architecture-specific
│       │   └── x86_64/
│       │       ├── index.md
│       │       ├── machine-dependent.md
│       │       └── assembly.md
│       │
│       ├── net/               # Networking
│       │   ├── index.md
│       │   └── ...
│       │
│       └── netinet6/          # IPv6
│           ├── index.md
│           └── ...
│
└── planning/                   # Planning docs (not in generated site)
    ├── sys/
    │   ├── PLAN.md
    │   └── kern/
    │       └── PLAN.md
    └── ...
```

### Key Design Decisions

1. **Separate `docs/` directory**
   - All user-facing documentation lives in `docs/`
   - MkDocs convention; clean separation from repo metadata
   - Easy to distinguish between planning docs and final docs

2. **Move PLAN.md files to `planning/`**
   - Planning documents are for agents/maintainers, not end users
   - Keep them in version control but exclude from generated site
   - Clear separation of concerns

3. **Mirror source structure within `docs/sys/`**
   - Maintains the mandate to mirror `~/s/dragonfly` structure
   - Intuitive mapping: source code path → docs path
   - Easy to find documentation for a specific source directory

4. **Use `index.md` for directory overviews**
   - Each directory gets an `index.md` that serves as its overview
   - Follows web convention and MkDocs best practices
   - Provides landing pages for each subsystem

5. **Group related content with subdirectories**
   - Large subsystems (like VFS) can have their own subdirectories
   - Balance between flat structure (easy navigation) and hierarchy (organization)
   - Use subdirectories sparingly, only when a topic has 5+ related docs

## MkDocs Configuration

### Minimal `mkdocs.yml`

```yaml
site_name: DragonFly BSD Kernel Documentation
site_description: Comprehensive documentation for the DragonFly BSD kernel source code
site_author: DragonFly BSD Community

# Repository (optional, for "Edit on GitHub" links)
# repo_url: https://github.com/your-org/dragonfly-docs
# repo_name: dragonfly-docs

theme:
  name: material
  palette:
    # Light mode
    - scheme: default
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-7
        name: Switch to dark mode
    # Dark mode
    - scheme: slate
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-4
        name: Switch to light mode
  features:
    - navigation.tabs
    - navigation.sections
    - navigation.expand
    - navigation.top
    - search.suggest
    - search.highlight
    - content.code.copy

markdown_extensions:
  - admonition
  - codehilite
  - toc:
      permalink: true
  - pymdownx.highlight
  - pymdownx.superfences
  - pymdownx.inlinehilite
  - pymdownx.keys
  - pymdownx.snippets
  - pymdownx.tabbed
  - pymdownx.details
  - def_list
  - footnotes

plugins:
  - search

# Navigation structure (optional, can be auto-generated)
nav:
  - Home: index.md
  - Getting Started: getting-started.md
  - Kernel Subsystems:
    - Overview: sys/index.md
    - kern/:
      - Overview: sys/kern/index.md
      - LWKT Threading: sys/kern/lwkt.md
      - Synchronization: sys/kern/synchronization.md
      - Memory Management: sys/kern/memory.md
      - Processes & Threads: sys/kern/processes.md
      - Scheduling: sys/kern/scheduling.md
      - Virtual Filesystem (VFS): sys/kern/vfs/index.md
      - IPC & Sockets: sys/kern/ipc.md
      - Devices & Drivers: sys/kern/devices.md
      - System Calls: sys/kern/syscalls.md
    - vm/:
      - Overview: sys/vm/index.md
    - cpu/x86_64/:
      - Overview: sys/cpu/x86_64/index.md
```

## Implementation Workflow

### Phase 1: Setup Infrastructure
1. Create `docs/` directory structure
2. Move planning documents to `planning/`
3. Create `mkdocs.yml` with initial configuration
4. Create `docs/index.md` (landing page)
5. Create `docs/getting-started.md` (how to use the docs)
6. Install MkDocs and test: `mkdocs serve`

### Phase 2: Create Subsystem Documentation (Incremental)
For each subsystem (following sys/kern/PLAN.md phases):
1. Read and understand the source code (per PLAN.md)
2. Create corresponding `.md` file in `docs/sys/kern/`
3. Write overview, key concepts, data structures, and flows
4. Add cross-references to related subsystems
5. Commit incrementally
6. Preview with `mkdocs serve`

### Phase 3: Enhance and Polish
1. Add diagrams (mermaid.js support via pymdownx.superfences)
2. Add code examples and snippets
3. Cross-link between documents
4. Add glossary if needed
5. Review and refine navigation structure

### Phase 4: Deployment (Future)
1. Generate static site: `mkdocs build`
2. Output goes to `site/` directory
3. Can be hosted on:
   - GitHub Pages
   - GitLab Pages
   - Netlify
   - Any static hosting service

## Content Guidelines

### Documentation File Structure

Each subsystem documentation file should follow this template:

```markdown
# Subsystem Name

Brief one-paragraph overview of the subsystem's purpose.

## Overview

Detailed description of:
- What this subsystem does
- Why it exists
- Where it fits in the kernel architecture

## Key Concepts

- Concept 1: explanation
- Concept 2: explanation

## Data Structures

### `struct foo`
Description, key fields, usage.

### `struct bar`
Description, key fields, usage.

## Key Functions

### `function_name()`
- **Purpose:** What it does
- **Called by:** Who calls it
- **Calls:** What it calls
- **Locks:** What locks it acquires

## Subsystem Interactions

How this subsystem interacts with:
- Other kernel subsystems
- Hardware
- Userspace

## Code Flow Examples

### Example: Typical Operation
Step-by-step walkthrough of a common operation.

## Files

List of key source files with brief descriptions:
- `kern_foo.c` — Main implementation
- `kern_foo.h` — Header (if in sys/sys/)

## References

- Links to related subsystems
- External documentation (if any)
- Papers or design documents
```

### Writing Style

- **Clear and concise** — Avoid unnecessary jargon
- **Assume C knowledge** — Reader knows C but not necessarily kernel internals
- **Focus on concepts first** — Explain the "why" before the "how"
- **Use examples** — Show concrete examples of data flows
- **Cross-reference heavily** — Link to related subsystems
- **Code references** — Use format `file.c:line` or `function_name()` to reference source

### Concepts Documentation Guidelines

When creating foundational "concepts" documentation (e.g., `concepts.md` files that introduce a subsystem's theory), follow these guidelines:

#### 1. Separate Theory from Implementation

- Create standalone `concepts.md` files for foundational theory and terminology
- Keep detailed implementation docs (e.g., `vm_page.md`, `vm_fault.md`) focused on DragonFly-specific code
- Link bidirectionally between concepts and implementation docs

#### 2. Target Audience: Kernel Developers (Varying Experience)

- Assume programming knowledge but not necessarily subsystem expertise
- Explain the "why" behind design decisions, not just the "what"
- Provide context for newcomers while remaining useful for experienced developers

#### 3. External Links Over Embedded Literature

- Link to authoritative external resources (textbooks, academic papers, BSD documentation)
- Don't reproduce full textbook explanations — keep explanations high-level
- Provide pointers to deep-dive materials for readers who want more

#### 4. Standard Structure for Concepts Docs

A concepts document should include:

1. **What is it?** — Brief definition of the subsystem
2. **Why does it matter?** — Use cases and benefits (consider using a table)
3. **Core terminology** — Glossary of key terms with external resource links
4. **Historical context** — Where the design came from (e.g., Mach VM heritage)
5. **DragonFly's evolution** — How DragonFly differs from the traditional design
6. **Visual aids** — 2-3 Mermaid diagrams illustrating key concepts
7. **Further reading** — Curated list of external resources
8. **See also** — Links back to implementation docs in this documentation

#### 5. Integration with Existing Documentation

When adding a concepts doc to a subsystem:

- Update the parent `index.md` to link the concepts doc prominently in the introduction
- Add to `mkdocs.yml` navigation right after the Overview entry
- Update "Reading Guide" tables to recommend concepts as the first stop for newcomers
- Adjust "Recommended reading order" to start with the concepts doc

#### 6. Avoid Premature Comparisons

- Focus on explaining DragonFly's design on its own merits first
- Note historical origins (Mach, BSD, etc.) for context
- Defer extensive comparative analysis with other BSDs until the core documentation is mature

### Markdown Conventions

- Use `code` for identifiers, functions, file names
- Use **bold** for emphasis
- Use *italic* for introducing new terms
- Use > blockquotes for important notes
- Use admonitions (Material theme) for warnings, tips, notes:
  ```markdown
  !!! note
      This is a note
  
  !!! warning
      This is a warning
  ```

## Advantages of This Design

1. **Clear separation** — Planning docs vs. final docs
2. **Standard tooling** — MkDocs is widely known and well-supported
3. **Fast iteration** — `mkdocs serve` provides instant preview
4. **Beautiful output** — Material theme is professional and readable
5. **Searchable** — Built-in search across all documentation
6. **Maintainable** — Plain Markdown files in git
7. **Mirrors source** — `docs/sys/` structure matches `~/s/dragonfly/sys/`
8. **Extensible** — Easy to add more subsystems incrementally

## Migration Path

1. **Start small** — Begin with LWKT documentation (Phase 0 of kern/PLAN.md)
2. **Iterate** — Add one subsystem at a time
3. **Refine structure** — Adjust navigation and organization as we learn what works
4. **Keep PLAN.md as reference** — Planning docs remain valuable as reading guides for contributors

## Current Status (as of 2025-12-15)

### Infrastructure
- ✅ MkDocs configured and operational (`mkdocs.yml` in place)
- ✅ Documentation structure established (`docs/` directory)
- ✅ Planning documents in `planning/sys/kern/PLAN.md`

### Completed Phases (sys/kern/)

#### Phases 0-6: Core Kernel Infrastructure
- ✅ Phase 0: LWKT threading (`docs/sys/kern/lwkt.md`)
- ✅ Phase 1a: Synchronization primitives (`docs/sys/kern/synchronization.md`)
- ✅ Phase 1b: Time and timers (`docs/sys/kern/time.md`)
- ✅ Phase 2: Memory allocation (`docs/sys/kern/memory.md`)
- ✅ Phase 3: Kernel initialization (`docs/sys/kern/initialization.md`)
- ✅ Phase 4a: Process/thread lifecycle (`docs/sys/kern/processes.md`)
- ✅ Phase 4b: Process resources/credentials (`docs/sys/kern/resources.md`)
- ✅ Phase 4c: Signals (`docs/sys/kern/signals.md`)
- ✅ Phase 5: CPU scheduling (`docs/sys/kern/scheduling.md`)
- ✅ Phase 6a: VFS initialization and core (`docs/sys/kern/vfs/index.md`)
- ✅ Phase 6b: VFS name lookup and caching (`docs/sys/kern/vfs/namecache.md`)
- ✅ Phase 6c: VFS mounting and syscalls (`docs/sys/kern/vfs/mounting.md`)
- ✅ Phase 6d: VFS buffer cache and I/O (`docs/sys/kern/vfs/buffer-cache.md`)
- ✅ Phase 6e: VFS operations and journaling (`docs/sys/kern/vfs/vfs-operations.md`, `docs/sys/kern/vfs/journaling.md`)
- ✅ Phase 6e: VFS locking and extensions (`docs/sys/kern/vfs/vfs-locking.md`, `docs/sys/kern/vfs/vfs-extensions.md`)

#### Phase 7: IPC and Socket Layer (Complete)
- ✅ Phase 7a1: Mbufs (`docs/sys/kern/ipc/mbufs.md`) - 801 lines
- ✅ Phase 7a2: Sockets (`docs/sys/kern/ipc/sockets.md`) - 1,098 lines
- ✅ Phase 7a3: Unix Domain Sockets (`docs/sys/kern/ipc/unix-sockets.md`) - 812 lines
- ✅ Phase 7a4: Protocol Dispatch (`docs/sys/kern/ipc/protocol-dispatch.md`) - 825 lines
- ✅ Phase 7c1: Pipes (`docs/sys/kern/ipc/pipes.md`) - 510 lines
- ✅ Phase 7c2: POSIX Message Queues (`docs/sys/kern/ipc/mqueue.md`) - 368 lines
- ✅ Phase 7b1: SysV Message Queues (`docs/sys/kern/ipc/sysv-msg.md`) - 312 lines
- ✅ Phase 7b2: SysV Semaphores (`docs/sys/kern/ipc/sysv-sem.md`) - 345 lines
- ✅ Phase 7b3: SysV Shared Memory (`docs/sys/kern/ipc/sysv-shm.md`) - 340 lines

### Pending Phases (sys/kern/)
- ⏳ Phase 8: Device infrastructure (`docs/sys/kern/devices.md` - stub only)
- ⏳ Phase 9: System calls and kernel linkage (`docs/sys/kern/syscalls.md` - stub only)
- ⏳ Phase 10: Monitoring, debugging, security
- ⏳ Phase 11: TTY subsystem
- ⏳ Phase 12: Utilities and miscellaneous

### Documentation Files

| File | Description | Status | Lines |
|------|-------------|--------|-------|
| `docs/sys/kern/lwkt.md` | LWKT threading subsystem | Complete | 740 |
| `docs/sys/kern/synchronization.md` | Locks, mutexes, serializers | Complete | 915 |
| `docs/sys/kern/time.md` | Timekeeping and timers | Complete | 1,403 |
| `docs/sys/kern/memory.md` | Memory allocation | Complete | 2,793 |
| `docs/sys/kern/initialization.md` | Kernel bootstrap | Complete | 1,167 |
| `docs/sys/kern/processes.md` | Process/thread lifecycle | Complete | 1,133 |
| `docs/sys/kern/resources.md` | Resource limits, credentials, FDs | Complete | 857 |
| `docs/sys/kern/signals.md` | Signal subsystem | Complete | 1,018 |
| `docs/sys/kern/scheduling.md` | CPU scheduling | Complete | 923 |
| `docs/sys/kern/vfs/index.md` | VFS core and initialization | Complete | 722 |
| `docs/sys/kern/vfs/namecache.md` | Name lookup and caching | Complete | 837 |
| `docs/sys/kern/vfs/mounting.md` | Filesystem mounting | Complete | 1,181 |
| `docs/sys/kern/vfs/buffer-cache.md` | Buffer cache and I/O | Complete | 1,666 |
| `docs/sys/kern/vfs/vfs-operations.md` | VFS operations | Complete | 847 |
| `docs/sys/kern/vfs/journaling.md` | Journaling support | Complete | 1,214 |
| `docs/sys/kern/vfs/vfs-locking.md` | Vnode locking and lifecycle | Complete | 569 |
| `docs/sys/kern/vfs/vfs-extensions.md` | VFS helpers, syncer, quotas | Complete | 627 |
| `docs/sys/kern/ipc/mbufs.md` | Memory buffer system | Complete | 801 |
| `docs/sys/kern/ipc/sockets.md` | Socket core layer | Complete | 1,098 |
| `docs/sys/kern/ipc/unix-sockets.md` | Unix domain sockets | Complete | 812 |
| `docs/sys/kern/ipc/protocol-dispatch.md` | Protocol domains, message-passing | Complete | 825 |
| `docs/sys/kern/ipc/pipes.md` | Pipe implementation | Complete | 510 |
| `docs/sys/kern/ipc/mqueue.md` | POSIX message queues | Complete | 368 |
| `docs/sys/kern/ipc/sysv-msg.md` | System V message queues | Complete | 312 |
| `docs/sys/kern/ipc/sysv-sem.md` | System V semaphores | Complete | 345 |
| `docs/sys/kern/ipc/sysv-shm.md` | System V shared memory | Complete | 340 |
| `docs/sys/kern/ipc.md` | IPC overview | Stub | 11 |
| `docs/sys/kern/devices.md` | Device infrastructure | Stub | 11 |
| `docs/sys/kern/syscalls.md` | System calls | Stub | 11 |

**Total documentation:** ~24,000+ lines

## Next Steps

1. **Phase 8: Device & Driver Infrastructure**
   - `devices.md` - Device framework (dev_ops, make_dev, NewBus)
   - `disk.md` - Disk layer (slices, labels, MBR/GPT)
   - `firmware.md` - Firmware loading subsystem
2. Continue with Phase 9: System calls and kernel linkage
3. Continue with Phase 10+: Monitoring, debugging, security, TTY, utilities
4. Add diagrams and cross-references as subsystems are completed
5. Deploy generated documentation when ready
