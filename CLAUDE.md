# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that runs one systemd-nspawn container per
project. On Linux the containers run natively on the host (config via
`nixosModules.host` in the host's NixOS configuration). On macOS they run in
one shared NixOS microVM (microvm.nix + qemu) that exists to provide a Linux
kernel. A project is any flake directory under a
configured workspace root (`devShells.default` is optional; see ADR-005) -- there are no nixcage-specific files in projects.
The primary use case is running AI coding agents in isolation.

nixcage runs cages; it has no opinion about what is built on them. What a
dependant may use is four exported primitives and nothing else (ADR-009):
`nixcage-container enter` with the flags that parameterise a session,
`nixcage-container uid <principal>`, `nixcage-container storage ensure`, and
`nixcage exec` to reach the machine the cages are on. cageworks, which runs a
factory of roles over one repository, is built entirely on those. Architecture:
`docs/ADR-002-shared-vm-project-containers.md`,
`docs/ADR-003-native-containers-on-linux.md` and
`docs/ADR-009-exported-primitives.md`; `docs/TRACKER.md` indexes the rest.

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
- `modules/enter-args.sh` -- the options `enter` is parameterised with. This is
  the exported interface, so it is a file the suite drives rather than a loop
  inside a Nix string (ADR-009).
- `modules/bind.sh` -- what a caller may map into a cage and where. `--bind`
  takes any host path, so the check that used to be implicit in "only our own
  code adds binds" is written here.
- `modules/principal-uid.sh` -- allocation of the uid a cage is mapped onto.
  A principal is whatever a caller wants a durable number for; nixcage promises
  only that one name always answers with one number and that none is reissued.
- `modules/storage.sh` -- a path given to a uid: a dataset where there is a
  pool and an ordinary directory where there is not (ADR-017 in cageworks,
  whose behaviour this inherited). Callers name paths, never datasets.
- `modules/nixcage.nix` -- the VM module (macOS path): nixcage options
  (`workspaceRoots`, `authorizedKeys`, `sshPort`, `shareProto`, `secretEnv`,
  `git.*`, `vm.*`, `principalUidRange`) and the VM base config.
- `modules/host.nix` -- the Linux host module: `workspaceRoots`, `secretEnv`,
  `git.*`, `storage.dataset` and `principalUidRange`; renders
  `/etc/nixcage/config` for the CLI and `/etc/nixcage/container` for the guest,
  installs the container layer on the host.
- `templates/config/` -- the flake template users instantiate at
  `~/.config/nixcage` (their VM configuration; sops-nix wired in).
- `examples/project/` -- an ordinary project flake showing the devShell
  interface.
- `flake.nix` -- packages nixcage, exports `nixosModules.nixcage` and
  `templates.config`, defines the dev shell.
- `docs/` -- ADRs and generated TRACKER.md.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, openssh
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats --recursive tests/
```

There is no build step -- the script runs directly (`bash nixcage help`).

The guest script is a Nix string, so it exists only once built, and building it
is what runs the shellcheck `writeShellApplication` does. Anything the VM
actually does is verified by building a probe from `templates/config` with the
nixcage input pointed at the working tree.

## Architecture

The script follows a command-dispatch pattern: `main()` at the bottom
dispatches to `cmd_*` functions (`enter`, `exec`, `down`, `rebuild`, `rm`,
`status`).

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

**Exec** (`cmd_exec`) -- the same transport with nothing else on it: argv runs
as root where the cages are, locally on Linux and over the VM's SSH on macOS.
It is how a dependant reaches `nixcage-container` without knowing this
machine's SSH key, port or state layout. Every word is quoted for the remote
shell, which re-splits the whole line rather than only the trailing arguments.

**The exported verbs** -- `uid` allocates from `nixcage.principalUidRange`,
monotonically, into `$STATE/principal-uids`; it was `role-uids` while the
factory lived here and is renamed in place, because a reissued number hands
something new the files of something dead. `storage ensure <path> <uid>
[quota]` derives the dataset name from the path relative to `/var/lib/nixcage`,
which is the only place the pool is mounted, and refuses a path outside it
rather than inventing a name.

**Guest container script** -- lives in `modules/container.nix` as a
`writeShellApplication`, shared unchanged by both platform modules; the host
script contains zero nspawn logic. Everything it does beyond nspawn mechanics
is a shell module sourced by store path, so shellcheck reads it and bats
sources it directly. Per
session it builds a throwaway rootfs skeleton (nspawn locks its directory,
so concurrent sessions need separate ones), binds the store read-only plus
the nix-daemon socket (`NIX_REMOTE=daemon`), the project dir at `/workspace`,
and the persistent home at `/root`, then execs `nix develop`.

**Git in a session** -- an ordinary repository needs nothing beyond the
project bind, but a linked worktree keeps its git directory inside the primary
repository: `nixcage_git_binds` (`modules/git-worktree.sh`) resolves the
administrative and common directories and they are bound at the exact path git
recorded (ADR-007). Identity comes from `nixcage.git.{userName,userEmail}`
rendered to `/etc/nixcage/gitconfig`, and signing goes through the user's
ssh-agent: `enter` forwards `SSH_AUTH_SOCK` (`ssh -A` on macOS, an explicit
`--auth-sock` past sudo on Linux) and the guest binds it at
`/run/ssh-agent.sock`. No key material enters a container (ADR-008).

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
  `modules/container.nix`, never inline in SSH command strings, and logic
  beyond nspawn mechanics goes in a `modules/*.sh` file the suite can source.
- Workspace roots mount at identical absolute paths in the VM, so the same
  project path is valid on host and guest -- code may rely on this.
- Nothing here knows what a caller is doing with a cage. A name for a caller's
  concept -- a role, a task, a factory -- reaching this repository is the sign
  that something belongs on the other side of ADR-009's interface.
