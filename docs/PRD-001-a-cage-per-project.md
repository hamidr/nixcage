---
id: PRD-001
title: A cage per project, entered with one command, on the machine the developer already has
status: implemented
date: 2026-09-17
status_date: 2026-09-17
summary: any flake directory enters an isolated container in one command, on Linux natively and on macOS in one shared VM
depends_on: []
supersedes: []
superseded_by: []
phases_total: 4
phases_done: 4
---

## Problem

A developer runs tools they do not fully trust inside projects they do. The
tool that made this urgent is an AI coding agent: it holds API keys, has the
network, and executes what it decides to execute, on the machine that also
holds every other project, the ssh keys, the browser sessions and the home
directory. Before nixcage the choices were process sandboxes (bwrap on
Linux, Seatbelt on macOS: the tool shares the host kernel, and every rule
is a hand-written policy that drifts), a VM per project (its own store, its
own boot, its own memory, and a nixcage-specific file in the project), or
Docker (a Dockerfile per project that says again what the flake already
says, and an image that is not the project's environment).

The people who hurt:

- **The developer** who wants to point an agent at a project and walk away,
  and cannot, because the agent can reach everything the developer can.
- **The Nix user** whose project already carries its whole environment in
  `flake.nix`, and who is asked by every isolation tool to describe it a
  second time in that tool's format.
- **The macOS user**, for whom containers do not exist, and who is offered
  either a VM per project or nothing.
- **The builder of something on top**, a factory of agents or a CI runner,
  who needs a cage as a primitive and finds every sandbox tool is a
  finished product with no seam.

The agent was the case that measured the tool. nixcage has no opinion about
what runs in a cage; it is a tool for giving one project one isolated place
to run, and that is all this document asks of it.

## Target users

- **Primary:** a developer on NixOS or macOS whose projects are flakes,
  running tools of uncertain trust inside them. Coding agents today; any
  tool tomorrow.
- **Secondary:** a dependant building on cages: cageworks (a factory of
  roles over one repository) is the one that exists; a CI runner or a
  per-tenant executor is the same shape.

Not a target: a user without Nix. The project's interface is its flake and
the machine's configuration is a NixOS module; there is no path around
either.

## Success metrics

- Entering a project is one command from anywhere under a configured
  workspace root: `nixcage enter <dir> [cmd...]`. The project carries no
  nixcage file. Measured: `examples/project` is an ordinary flake and
  enters.
- Inside the cage, the project is at the same absolute path as outside, so
  a path pasted in either place is valid in the other.
- A session cannot reach another project, the home directory, or a key: the
  store is read-only, only the project and its declared binds are mounted,
  git signs through a forwarded agent and no key material crosses in
  (ADR-008), and the session runs as the project owner's uid, not root
  (ADR-004, ADR-010).
- The environment inside is the project's own: `devShells.default` when
  declared, direnv when there is an `.envrc`, the base userland otherwise
  (ADR-005, ADR-006). Nothing nixcage-specific is visible from the shell.
- Git works as on the host, including in a linked worktree (ADR-007) and
  with signing (ADR-008).
- The same command and the same semantics on Linux and macOS; only the
  transport differs (ADR-003). Measured: the suite runs the CLI under
  `NIXCAGE_OS` for both.
- A dependant needs nothing beyond four argv primitives (ADR-009) and can be
  pinned to them by `flake.lock`. Measured: cageworks builds on them and on
  nothing else in this repository.
- Every promise above is a test the suite runs without a VM; what the VM
  does is verified by a probe built from `templates/config`.

## Scope

In:

- One container per project, created imperatively at enter, in a shared
  place: the host itself on Linux, one NixOS microVM on macOS (ADR-002,
  ADR-003).
- The project's flake as its whole interface; a config flake owned by the
  user for the machine's side (ADR-002).
- Sessions under the owner's uid with a block of uids per principal, so a
  cage may hold subjects that do not trust each other (ADR-004, ADR-010).
- Environment selection, git in worktrees, identity and signing without
  keys inside (ADR-005 to ADR-008).
- Secrets through sops-nix only, injected per session, never read from the
  host environment (ADR-002).
- The four exported primitives: a parameterised session, a principal's uid,
  owned bounded storage, and a way to reach the machine the cages are on
  (ADR-009).
- What a dependant asked for and nixcage owns because it is about the cage,
  not the caller: a private network placement with a made and named veth,
  pinned address and no resolver unless told (ADR-011, ADR-013, ADR-015,
  ADR-016, ADR-018); a scope with status, netns and stop, and memory and
  cpu bounds (ADR-012); a session without the daemon that sees only the
  closure of its roots (ADR-014); a record of what each cage was given
  (ADR-017).

Out, explicitly:

- **What runs in a cage.** No agent is installed, configured or known. A
  role, a task, a factory reaching this repository is a sign that
  something belongs on the other side of ADR-009's interface.
- **Orchestration.** Several cages working one repository is cageworks.
- **A cluster.** A cage on a machine the developer does not own is another
  document.
- **Process-level sandboxing.** Superseded by ADR-001 and not returned to;
  on Linux the accepted trade is that host-versus-tool isolation rests on
  the container boundary alone (ADR-003).
- **A per-project VM.** ADR-001, superseded by ADR-002.
- **Users without Nix.**

## Requirements

Each is a behaviour the suite watches. The ADR in brackets is where the
mechanism is decided.

- R1. A flake directory under a configured workspace root enters in one
  command with no nixcage file in the project [ADR-002].
- R2. A directory outside every workspace root, or without `flake.nix`, is
  refused with the reason before anything boots [ADR-002].
- R3. The project is mounted at its own absolute path; the store is
  read-only; a persistent home survives sessions [ADR-002].
- R4. On Linux the container runs on the host with no VM; on macOS one VM
  serves every project and boots on first enter; `rebuild` and `down` exist
  only where the VM does [ADR-003].
- R5. The session runs as the project owner's uid; a principal is given a
  contiguous block so subjects inside one cage can be separated [ADR-004,
  ADR-010].
- R6. The shell inside is the devShell when declared, direnv when there is
  an `.envrc`, the base userland otherwise, in that order [ADR-005,
  ADR-006].
- R7. Git works in a linked worktree, commits under the declared identity,
  and signs through the forwarded agent with no key in the cage [ADR-007,
  ADR-008].
- R8. A secret reaches a session only through sops-nix and `secretEnv`;
  the host environment is never read [ADR-002].
- R9. A dependant can parameterise a session (`--uid`, `--user`, `--home`,
  `--bind`, `--bind-ro`, `--setenv`, `--shell`, `--no-agent`, `--subject`),
  ask for a principal's uid and never get a reissued one, ask for owned
  bounded storage by path, and reach the cage host with `nixcage exec`
  [ADR-009]. A bind to a destination that would break the cage is refused
  [ADR-009].
- R10. A session may be placed on a named bridge at a named address, with a
  veth nixcage makes and names, speaking only as that address and only to
  the machine, resolving nothing unless told where; the bridge is declared
  on the host module [ADR-011, ADR-013, ADR-015, ADR-016, ADR-018].
- R11. A running cage answers `status`, `netns`, `stop` and `exec`, has
  memory and cpu bounds from enter, and `list --json` says what each was
  given [ADR-012, ADR-017].
- R12. A session without the daemon sees the closure of its roots and
  nothing else of the store; `--store-root` names a root [ADR-014].

## Phases

1. **One shared VM, one container per project** (ADR-001, ADR-002). Done.
2. **Native on Linux; the session is the project's** (ADR-003 to ADR-008).
   Done.
3. **The interface a dependant sees** (ADR-009, ADR-010). Done; cageworks
   left and builds on it.
4. **What a dependant asked for and the cage owns** (ADR-011 to ADR-018).
   Done. Every requirement has its module and its tests (296 in the suite,
   0 failing on 2026-09-17), and the behaviour has been exercised on the
   Linux host repeatedly.

## Open questions

None for the product. Bookkeeping lags it: ADR-011, ADR-012 and ADR-013
read `proposed`, ADR-014 and ADR-018 `implementing`, and each keeps a
"recorded here when run" line for a machine run that has since happened.
`adr-go` on each records the run and flips the status; ADR-013 also names
the part ADR-015 withdrew.

## Consequences

This document is written after the fact, on 2026-09-17, so that the next
product document has a thing to depend on and so that the product the ADRs
decided piecewise is stated once as a whole. Where it and an ADR disagree, the ADR is the
decision and this document is the summary that needs fixing.
