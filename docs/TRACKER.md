# ADR & PRD Tracker

GENERATED FILE -- do not edit. Rebuild with `docmeta-tracker <docs-root>`.
Every fact here comes from the frontmatter of the document it names; change the
document, then regenerate.

**Generated:** 2026-08-29

**Next PRD number:** 001

**Next ADR number:** 005

## ADRs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [ADR-001](ADR-001-vm-microvm-architecture.md) | NixOS microVM as the sole execution model | superseded | -- | -- | Replace bwrap/Seatbelt process sandboxing with one per-project NixOS microVM managed by nixcage |  |
| [ADR-002](ADR-002-shared-vm-project-containers.md) | One shared VM with per-project containers; plain flake devShell as the interface | implemented | -- | -- | Replace per-project microVMs with one shared VM running imperative nspawn containers driven by plain devShells |  |
| [ADR-003](ADR-003-native-containers-on-linux.md) | Containers run natively on Linux; the VM becomes a macOS kernel shim | implemented | -- | ADR-002 | Linux hosts run project nspawn containers directly; the shared VM remains only where a Linux kernel is missing |  |
| [ADR-004](ADR-004-container-uid-mapping.md) | Container sessions run under the project owner's uid, not real root | implemented | -- | ADR-003 | nspawn maps the container onto the project owner's uid instead of running sessions as real root |  |
