# Agent Guidelines for `dragonfly-docs`

1. **Repository being documented**
   - This repository (`~/s/dragonfly-docs`) documents the source repository at `~/s/dragonfly`, which is primarily written in C.

2. **Mirror the source tree structure**
   - Documentation must follow the directory layout of `~/s/dragonfly`.
   - For any source directory `PATH` in `~/s/dragonfly` (for example, `sys/kern`), place its documentation in the matching path `PATH` within this repository (for example, `sys/kern/` under `~/s/dragonfly-docs`).

3. **Documentation location**
   - All documentation files must live in this repository only (`~/s/dragonfly-docs`).
   - Do not write documentation into `~/s/dragonfly` or into directories outside this docs repository.

4. **Documentation format and output**
   - The end goal is to generate publishable documentation that can be rendered using a static site generator (such as MkDocs).
   - `PLAN.md` files serve only as reading and planning guides; they are not the final documentation.
   - Create actual Markdown documentation files (`.md`) that explain subsystems, data structures, and code flows in a clear, accessible manner.
   - These documentation files will be the consumable output for users trying to understand the DragonFly BSD kernel.

5. **Commit discipline**
   - Make small, focused commits frequently.
   - Avoid bundling large, unrelated changes into a single commit.
   - Before committing, review and adjust documentation for accuracy, clarity, and completeness.
   - Ensure all cross-references, code locations (file:line), and technical details are correct.

6. **No pushing to remotes**
   - Never run `git push` or any other command that modifies remote repositories.

7. **System safety**
   - Do not run commands that are dangerous to the host operating system (for example, destructive filesystem operations, disk formatting, low-level system reconfiguration, or privilege-escalation tooling).