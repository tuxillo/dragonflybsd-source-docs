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

## Current Status (as of 2025-11-30)

### Infrastructure
- ✅ MkDocs configured and operational (`mkdocs.yml` in place)
- ✅ Documentation structure established (`docs/` directory)
- ✅ Planning documents in `planning/sys/kern/PLAN.md`

### Completed Phases (sys/kern/)
- ✅ Phase 2: Memory allocation (kern_kmalloc.c, kern_slaballoc.c, kern_objcache.c, kern_mpipe.c)
- ✅ Phase 3: Kernel initialization (init_main.c, init_sysent.c)
- ✅ Phase 4a: Process/thread lifecycle (kern_fork.c, kern_exec.c, kern_exit.c, kern_proc.c, kern_threads.c, imgact_*.c)
- ✅ Phase 4b: Process resources/credentials (kern_resource.c, kern_plimit.c, kern_prot.c, kern_descrip.c) - 857 lines
- ✅ Phase 4c: Signals (kern_sig.c) - 1,018 lines
- ✅ Phase 5: CPU scheduling (6 files: kern_sched.c, kern_synch.c, kern_usched.c, usched_*.c) - 924 lines
- ✅ Phase 6a: VFS initialization and core (7 files: vfs_init.c, vfs_conf.c, vfs_subr.c, vfs_vfsops.c, vfs_vnops.c, vfs_vopops.c, vfs_default.c) - 729 lines

### In Progress
- 🔄 Phase 6b: VFS name lookup and caching (vfs_cache.c, vfs_nlookup.c, vfs_lookup.c)

### Pending Phases (sys/kern/)
- ⏳ Phase 0: LWKT (lightweight kernel threading)
- ⏳ Phase 1a: Synchronization primitives
- ⏳ Phase 1b: Time and timers
- ⏳ Phase 6c: VFS mounting and syscalls
- ⏳ Phase 6d: VFS buffer cache and I/O
- ⏳ Phase 6e: VFS extensions (locking, journaling, quota, AIO)
- ⏳ Phase 7: IPC and socket layer
- ⏳ Phase 8+: Device infrastructure, TTY, system calls, etc.

### Documentation Statistics
- **Total commits:** 4 (latest session)
- **Total documentation lines:** ~3,528 (latest session)
- **Source files analyzed:** 17 (latest session, 23,792 lines)
- **Repository status:** 4 commits ahead of origin/master
- **Working tree:** Clean

### Documentation Files
- `docs/sys/kern/memory.md` - Memory allocation subsystem
- `docs/sys/kern/initialization.md` - Kernel bootstrap
- `docs/sys/kern/processes.md` - Process/thread lifecycle
- `docs/sys/kern/resources.md` - Resource limits, credentials, file descriptors
- `docs/sys/kern/signals.md` - Signal subsystem
- `docs/sys/kern/scheduling.md` - CPU scheduling
- `docs/sys/kern/vfs/index.md` - VFS initialization and core

## Next Steps

1. Complete Phase 6b: VFS name lookup and caching
2. Continue with remaining VFS phases (6c, 6d, 6e)
3. Address Phase 0 and Phase 1 (foundational subsystems)
4. Continue with Phase 7+ (IPC, devices, TTY, syscalls)
5. Add diagrams and cross-references as subsystems are completed
6. Deploy generated documentation when ready
