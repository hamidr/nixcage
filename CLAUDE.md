# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that runs one systemd-nspawn container per
project. On Linux the containers run natively on the host (config via
`nixosModules.host` in the host's NixOS configuration). On macOS they run in
one shared NixOS microVM (microvm.nix + qemu) that exists to provide a Linux
kernel. A project is any flake directory under a
configured workspace root (`devShells.default` is optional; see ADR-005) -- there are no nixcage-specific files in projects.
The primary use case is running AI coding agents in isolation. Architecture:
`docs/ADR-002-shared-vm-project-containers.md` and
`docs/ADR-003-native-containers-on-linux.md`.

## Repository layout

- `nixcage` -- the entire host-side tool: a single self-contained Bash script.
  All commands, the platform transport seam, and VM lifecycle logic live here.
- `modules/container.nix` -- the shared container layer: the minimal userland
  profile and the `nixcage-container` script owning all nspawn mechanics.
  Used unchanged by both platform modules.
- `modules/dev-shell.sh` -- guest-side environment selection, sourced into the
  session by store path: direnv when the project has an `.envrc`, else the
  devShell, else the base userland. A shell file rather than an inline string
  so shellcheck reads it and bats sources it.
- `modules/git-worktree.sh` -- resolution of the git directories a linked
  worktree points at, sourced by store path into `nixcage-container`. A shell
  file for the same reason `dev-shell.sh` is one.
- `modules/nixcage.nix` -- the VM module (macOS path): nixcage options
  (`workspaceRoots`, `authorizedKeys`, `sshPort`, `shareProto`, `secretEnv`,
  `vm.*`) and the VM base config.
- `modules/host.nix` -- the Linux host module: `workspaceRoots` + `secretEnv`
  options, renders `/etc/nixcage/config` for the CLI, installs the container
  layer on the host.
- `templates/config/` -- the flake template users instantiate at
  `~/.config/nixcage` (their VM configuration; sops-nix wired in).
- `examples/project/` -- an ordinary project flake showing the devShell
  interface.
- `flake.nix` -- packages nixcage, exports `nixosModules.nixcage` and
  `templates.config`, defines the dev shell.
- `docs/` -- ADRs and generated TRACKER.md.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, openssh
nix develop --command shellcheck nixcage
nix develop --command bats --recursive tests/
```

There is no build step -- the script runs directly (`bash nixcage help`).

## Architecture

The script follows a command-dispatch pattern: `main()` at the bottom
dispatches to `cmd_*` functions (`enter`, `down`, `rebuild`, `rm`, `status`).

### Key subsystems

**Config flake resolution** -- `--flake` > `NIXCAGE_FLAKE` > `~/.config/nixcage`.
`resolve_vm_attr` picks `nixosConfigurations."nixcage-<hostname -s>"` when the
flake has it, else `nixosConfigurations.nixcage` (nixos-rebuild hostname
convention; lets one flake serve several machines). The CLI never writes into
the flake; `check_flake` errors with template guidance when it is missing.

**Build cache** (`vm_build`, `vm_read_cache`) -- `rebuild` runs `nix build` on
`...microvm.declaredRunner` into `$STATE/result`, then `nix eval`s `sshPort`
and `workspaceRoots` into `$STATE/cache` so `enter` never pays an eval.
`STATE` is `${XDG_STATE_HOME:-~/.local/state}/nixcage`; it also holds the
lazily generated SSH keypair (public key must be pasted into
`nixcage.authorizedKeys`), known_hosts, pid, and log files.

**VM lifecycle** (`vm_start`, `cmd_down`) -- launches the runner in the
background from `$STATE` (virtiofsd and qemu talk over a relative socket
path, so they must share a CWD), waits for SSH, records the pid.
`vm_start_virtiofsd` bypasses the supervisord wrapper microvm.nix generates
(it insists on root) and execs the individual virtiofsd commands.

**Enter** (`cmd_enter`) -- validation order matters: flake.nix present, path
under a workspace root, then boot the VM. Derives the container name
(`container_name_for`: sanitized basename + 8-char path hash) and runs
`sudo nixcage-container enter <name> <path> [cmd...]` over SSH (`-t` when
interactive).

**Guest container script** -- lives in `modules/nixcage.nix` as a
`writeShellApplication`; the host script contains zero nspawn logic. Per
session it builds a throwaway rootfs skeleton (nspawn locks its directory,
so concurrent sessions need separate ones), binds the store read-only plus
the nix-daemon socket (`NIX_REMOTE=daemon`), the project dir at `/workspace`,
and the persistent home at `/root`, then execs `nix develop`.

**Git in a session** -- an ordinary repository needs nothing beyond the
project bind, but a linked worktree keeps its git directory inside the primary
repository: `nixcage_git_binds` (`modules/git-worktree.sh`) resolves the
administrative and common directories and they are bound at the exact path git
recorded (ADR-007).

**Secrets** -- sops-nix in the user's config flake; age key generated on the
VM data volume at first boot; `nixcage.secretEnv` maps env vars to secret
names, injected per session by the guest script from `/run/secrets`. The
host environment is never read.

### Platform branching

`detect_os()` (overridable with `NIXCAGE_OS` for tests) selects the
transport: Linux executes `sudo nixcage-container` locally and reads
`/etc/nixcage/config` (`NIXCAGE_HOST_CONFIG` override for tests);
macOS goes over SSH into the VM and reads the build-time cache. `cfg_read`
is the dispatch point. `rebuild`/`down` are macOS-only
(`require_vm_platform`); on Linux the host owns the lifecycle via
nixos-rebuild. The macOS hypervisor is qemu because microvm.nix supports
`forwardPorts` (our SSH path) only with qemu user-mode networking.

## Conventions

- `VM_*` prefix for globals set by `vm_read_cache`.
- `vm_*` prefix for VM lifecycle/SSH helpers, `cmd_*` for command handlers.
- Guest-side container logic goes in `nixcage-container` inside
  `modules/nixcage.nix`, never inline in SSH command strings.
- Workspace roots mount at identical absolute paths in the VM, so the same
  project path is valid on host and guest -- code may rely on this.
