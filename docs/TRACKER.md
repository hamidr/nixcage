# ADR & PRD Tracker

GENERATED FILE -- do not edit. Rebuild with `docmeta-tracker <docs-root>`.
Every fact here comes from the frontmatter of the document it names; change the
document, then regenerate.

**Generated:** 2026-08-28

**Next PRD number:** 001

**Next ADR number:** 003

## ADRs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [ADR-001](ADR-001-vm-microvm-architecture.md) | NixOS microVM as the sole execution model | superseded | -- | -- | Replace bwrap/Seatbelt process sandboxing with one per-project NixOS microVM managed by nixcage |  |
| [ADR-002](ADR-002-shared-vm-project-containers.md) | One shared VM with per-project containers; plain flake devShell as the interface | proposed | -- | -- | Replace per-project microVMs with one shared VM running imperative nspawn containers driven by plain devShells |  |
