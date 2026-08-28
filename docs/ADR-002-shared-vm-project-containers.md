---
id: ADR-002
title: One shared VM with per-project containers; plain flake devShell as the interface
status: implementing
date: 2026-08-28
status_date: 2026-08-28
summary: Replace per-project microVMs with one shared VM running imperative nspawn containers driven by plain devShells
depends_on: []
supersedes: [ADR-001]
superseded_by: []
---

## Context

ADR-001 gave every project its own microVM configured through a project-local
`nixcage.vm.nix`. In practice this has three costs. Each project pays the full
VM price: its own Nix store, its own boot, its own memory reservation.
`nixcage.vm.nix` is a nixcage-specific artifact in the project repo, so a
project is not usable without knowing nixcage. And the generated per-project
`.nixcage-vm/` directory (flake, config, keys, hashes) plus the shell hook add
a lot of imperative state and script machinery.

The users are Nix users. A project already carries the only interface it
should need: its own `flake.nix` with `devShells.default`. Isolation between
projects does not require one kernel per project; a container boundary between
projects inside one VM is enough, with the VM boundary still separating
everything from the host.

## Decision

One shared VM per user and machine; one systemd-nspawn container per project
inside it. The decisions, in order of user visibility:

**1. A project's interface is its own `flake.nix` with `devShells.default`.**
No nixcage file exists in the project. `nixcage.vm.nix`, the generated
per-project `.nixcage-vm/` directory, `nixcage init`, and the cd shell hook
are all removed. Any flake directory under a configured workspace root can be
entered.

**2. The VM is configured by a user-owned config flake, not scaffolded state.**
nixcage exports `nixosModules.nixcage` (VM base plus options:
`nixcage.workspaceRoots`, `nixcage.vm.{cpus,mem,diskSize}`,
`nixcage.secretEnv`) and a flake template (`nix flake init -t <nixcage>#config`).
The user writes and owns the config flake; arbitrary NixOS configuration is
allowed in it. The CLI locates it via `--flake`, `NIXCAGE_FLAKE`, or the
default `~/.config/nixcage`. The host script reads values it needs (workspace
roots, port) from the same flake via `nix eval`, so the flake is the single
source of truth. Machine state that is not configuration (SSH keypair, random
SSH port, pid file, data volume) is generated lazily on first start under
`~/.local/state/nixcage/`.

**3. One shared VM; containers are created imperatively.**
The VM (microvm.nix; cloud-hypervisor on Linux, QEMU with an aarch64-linux
guest on macOS, virtiofs vs. 9p, as in ADR-001) boots once and persists: a
data volume holds the VM's own Nix store and per-project container homes. The
VM's store is independent of the host store and is shared read-only into every
container. Workspace roots are mounted into the VM once; each container
bind-mounts only its own project subdirectory as `/workspace` plus its
persistent home. Containers are created on demand with `nixos-container`
style imperative nspawn, so adding a project never rebuilds or restarts the
VM. Declarative per-project containers were rejected because every project
add would rebuild and restart the shared VM, killing other projects'
sessions.

**4. Secrets go through sops-nix only.**
The config flake imports sops-nix and carries an encrypted secrets file. The
age key is generated on first boot inside the VM and never leaves the data
volume; `nixcage status` prints its public key for `.sops.yaml`. The VM
decrypts to `/run/secrets` at boot, and `nixcage.secretEnv` maps environment
variable names to secret names, sourced into each container session at enter
time. The host environment is never read. Persistent container homes cover
interactive logins (for example `claude login`). nixcage installs no AI tools;
a project that wants claude-code lists it in its own devShell.

**5. Five CLI commands.**
`enter [-- cmd]` (auto-starts the VM, creates the container if missing, runs
`nix develop` in `/workspace`, interactive or one-shot), `down`, `rebuild`
(applies config flake changes; explicit because it restarts the shared VM),
`rm <project>` (deletes container and persistent home), `status`. `setup`,
`up`, `run`, `gc`, and the hook installer are removed.

## Consequences

- Projects need zero nixcage-specific files; any flake works unmodified.
  Cost: no per-project VM tuning; all projects share one VM sizing.
- One VM amortizes boot, memory, and store across projects; first
  `nix develop` per project builds inside the VM store, later enters are
  cached. Cost: projects share a kernel and the VM network; project-to-project
  isolation is a container boundary, weaker than ADR-001's VM-per-project.
  No per-container network policy exists yet.
- `rebuild` restarts the shared VM and interrupts every project's session;
  that is why it is the only implicit-free, deliberate command.
- The VM store duplicates host store contents (accepted for isolation:
  the guest never sees host store paths).
- Imperative container creation lives in script logic rather than Nix; the
  declarative-template variant remains an upgrade path if container
  configuration grows.
- Breaking change, major version bump. Existing projects run `nixcage destroy`
  with the old binary (or delete `.nixcage-vm/` and `nixcage.vm.nix` by hand)
  before migrating.
