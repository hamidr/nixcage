# ADR & PRD Tracker

GENERATED FILE -- do not edit. Rebuild with `docmeta-tracker <docs-root>`.
Every fact here comes from the frontmatter of the document it names; change the
document, then regenerate.

**Generated:** 2026-09-01

**Next PRD number:** 003

**Next ADR number:** 009

## PRDs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [PRD-001](PRD-001-actor-mailbox.md) | A mailbox that lets project containers exchange messages | proposed | 0/4 | -- | give each project actor a durable mailbox so agents in separate containers can signal, delegate, and share findings |  |
| [PRD-002](PRD-002-autonomous-workflow-supervisor.md) | A supervisor that runs declared workflows across cages | proposed | 0/5 | PRD-001 | declared workflows dispatch caged agent runs under gates and caps, so runs start without a human |  |

## ADRs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [ADR-001](ADR-001-vm-microvm-architecture.md) | NixOS microVM as the sole execution model | superseded | -- | -- | Replace bwrap/Seatbelt process sandboxing with one per-project NixOS microVM managed by nixcage |  |
| [ADR-002](ADR-002-shared-vm-project-containers.md) | One shared VM with per-project containers; plain flake devShell as the interface | implemented | -- | -- | Replace per-project microVMs with one shared VM running imperative nspawn containers driven by plain devShells |  |
| [ADR-003](ADR-003-native-containers-on-linux.md) | Containers run natively on Linux; the VM becomes a macOS kernel shim | implemented | -- | ADR-002 | Linux hosts run project nspawn containers directly; the shared VM remains only where a Linux kernel is missing |  |
| [ADR-004](ADR-004-container-uid-mapping.md) | Container sessions run under the project owner's uid, not real root | implemented | -- | ADR-003 | nspawn maps the container onto the project owner's uid instead of running sessions as real root |  |
| [ADR-005](ADR-005-optional-dev-shell.md) | A project without a devShell enters the base container shell | implemented | -- | ADR-002 | sessions probe the flake and fall back to the base container shell when it defines no devShell |  |
| [ADR-006](ADR-006-direnv-project-environments.md) | A project with an .envrc is entered through direnv | implemented | -- | ADR-005 | sessions run direnv when the project has an .envrc, so those projects get the same environment as on the host |  |
| [ADR-007](ADR-007-worktree-git-directory-bind.md) | A linked git worktree binds its git directory into the session | implemented | -- | ADR-002 | sessions bind the git directories a linked worktree points at, so git works in a worktree instead of failing outright |  |
| [ADR-008](ADR-008-session-git-identity-and-signing.md) | Sessions commit under a declared identity and sign through the forwarded ssh-agent | implemented | -- | ADR-007 | sessions get a declared git identity and sign through the forwarded ssh-agent, holding no key of their own |  |
