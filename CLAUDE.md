# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that runs one shared NixOS microVM (via
microvm.nix, qemu on both platforms) with one systemd-nspawn container per
project inside it. A project is any flake directory with `devShells.default`
under a configured workspace root -- there are no nixcage-specific files in
projects. The primary use case is running AI coding agents (claude-code,
opencode) in VM-level isolation from the host with a container boundary
between projects. Architecture decision: `docs/ADR-002-shared-vm-project-containers.md`.

## Repository layout

- `nixcage` -- the entire host-side tool: a single self-contained Bash script.
  All commands and VM lifecycle logic live here.
- `modules/nixcage.nix` -- the NixOS module: nixcage options
  (`workspaceRoots`, `authorizedKeys`, `sshPort`, `shareProto`, `secretEnv`,
  `vm.*`), the VM base config, and the guest-side `nixcage-container` script
  that owns all nspawn mechanics.
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
The flake must export `nixosConfigurations.nixcage`. The CLI never writes into
it; `check_flake` errors with template guidance when it is missing.

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

**Secrets** -- sops-nix in the user's config flake; age key generated on the
VM data volume at first boot; `nixcage.secretEnv` maps env vars to secret
names, injected per session by the guest script from `/run/secrets`. The
host environment is never read.

### Platform branching

`detect_os()` selects timeouts and nothing else at runtime. Platform
divergence (9p vs virtiofs, `vmHostPackages`) lives in the user's config
flake, guided by the template comments. The hypervisor is qemu everywhere
because microvm.nix supports `forwardPorts` (our SSH path) only with qemu
user-mode networking.

## Conventions

- `VM_*` prefix for globals set by `vm_read_cache`.
- `vm_*` prefix for VM lifecycle/SSH helpers, `cmd_*` for command handlers.
- Guest-side container logic goes in `nixcage-container` inside
  `modules/nixcage.nix`, never inline in SSH command strings.
- Workspace roots mount at identical absolute paths in the VM, so the same
  project path is valid on host and guest -- code may rely on this.
