# ADR & PRD Tracker

GENERATED FILE -- do not edit. Rebuild with `docmeta-tracker <docs-root>`.
Every fact here comes from the frontmatter of the document it names; change the
document, then regenerate.

**Generated:** 2026-09-22

**Next PRD number:** 003

**Next ADR number:** 023

## PRDs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [PRD-001](PRD-001-a-cage-per-project.md) | A cage per project, entered with one command, on the machine the developer already has | implementing | 4/5 | -- | any directory under a workspace root enters an isolated container in one command, natively on Linux and in a VM on macOS |  |
| [PRD-002](PRD-002-a-flake-closure-as-a-kubernetes-volume.md) | A flake's closure reaches a Kubernetes pod as a volume, not as an image | proposed | 0/3 | PRD-001, ADR-009, ADR-011, ADR-014 | one flake root runs in a cage locally and, via nixkube, in a pod; nixcage pushes it and emits the fragment |  |

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
| [ADR-009](ADR-009-exported-primitives.md) | nixcage exports four primitives and nothing else | implemented | -- | ADR-002, ADR-003, ADR-004 | a session, a principal's uid, owned storage and a way to reach the cage host are the whole interface a dependant sees |  |
| [ADR-010](ADR-010-a-cage-maps-a-block-of-uids.md) | A cage maps a block of uids, and a session need not be root | implemented | -- | ADR-004, ADR-009 | a principal gets a contiguous block rather than one number, so a cage can hold subjects that do not trust each other |  |
| [ADR-011](ADR-011-a-cage-on-a-private-network-and-without-the-daemon.md) | A cage may be placed on a private network, and may be given no nix daemon | proposed | -- | ADR-009, ADR-010 | two enter options a dependant asked for: one veth on a named bridge at a named address, and no daemon socket |  |
| [ADR-012](ADR-012-a-cage-has-a-scope-and-nixcage-answers-for-it.md) | A cage has a scope, and nixcage answers for it | proposed | -- | ADR-009, ADR-011 | status, netns and stop for a running cage from the scope nspawn gives it; memory and cpu bounds set on it at enter |  |
| [ADR-013](ADR-013-nixcage-makes-the-veth-and-names-it.md) | nixcage makes a cage's veth and names it, so a cage name is not bounded by an interface name | proposed | -- | ADR-011, ADR-012 | for a bridge placement nixcage makes the veth pair, names the host end from a hash, and tells the caller that name |  |
| [ADR-014](ADR-014-a-cage-without-the-daemon-sees-only-its-closure.md) | A cage without the daemon sees the closure of its roots, not the store | implementing | -- | ADR-009, ADR-011 | enter --no-nix-daemon binds each path of its roots' closure and nothing else of /nix/store; --store-root names a root |  |
| [ADR-015](ADR-015-a-bridged-cage-speaks-only-as-its-address-and-to-the-machine-alone.md) | A bridged cage speaks only as its address, and reaches the machine and never a peer | implemented | -- | ADR-011, ADR-013 | nixcage pins a placement address on its port and isolates the port; the two bridge rules a dependant wrote are its own |  |
| [ADR-016](ADR-016-a-bridged-cage-resolves-nothing-unless-told-where.md) | A bridged cage resolves nothing unless told where | implemented | -- | ADR-011 | enter --dns none\|<address> decides the cage's resolver; a private-network session defaults to none, not the host's file |  |
| [ADR-017](ADR-017-nixcage-lists-what-runs-with-what-it-was-given.md) | nixcage lists what runs, with what each cage was given | implemented | -- | ADR-011, ADR-012 | list --json reports each cage's name, uid, subject, placement, scope and leader from state nixcage recorded at enter |  |
| [ADR-018](ADR-018-the-host-module-owns-a-bridge-a-cage-may-be-placed-on.md) | The host module owns a bridge a cage may be placed on | implementing | -- | ADR-003, ADR-011, ADR-015 | nixcage.bridges.<name> declares a bridge with its address and the two settings an empty bridge needs to be usable |  |
| [ADR-019](ADR-019-a-cage-may-run-in-a-microvm-behind-the-same-enter.md) | A cage may run in a microVM under systemd-vmspawn, chosen when the cage is defined, behind the same enter | implemented | -- | ADR-003, ADR-009, ADR-010, ADR-011, ADR-012, ADR-014, ADR-017 | enter --substrate microvm boots a NixOS guest with vmspawn from the same parse; own kernel, no daemon, same verbs |  |
| [ADR-020](ADR-020-a-file-crosses-into-a-microvm-staged-in-a-directory-of-its-own.md) | A file asked as a bind crosses into a microVM staged in a directory of its own, and lands where the same enter on nspawn puts it | implemented | -- | ADR-009, ADR-019 | a file bind works on microvm; the host stages a copy in a shared directory and the guest binds it onto its target |  |
| [ADR-021](ADR-021-a-project-is-any-directory-under-a-workspace-root.md) | A project is any directory under a workspace root, not only a flake directory | implemented | -- | ADR-002, ADR-005 | enter validates the workspace root alone; a directory with no flake.nix opens the base container shell |  |
| [ADR-022](ADR-022-a-cage-is-bounded-by-what-the-host-declares.md) | A cage is bounded by what the host declares, and a session may ask for something else | implemented | -- | ADR-003, ADR-009, ADR-012, ADR-017, ADR-019 | nixcage.bounds and cages.<path>.bounds give memory and cpus to both substrates; the flag still wins |  |
