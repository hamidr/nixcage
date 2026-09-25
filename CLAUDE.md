# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that runs one cage per project: a
systemd-nspawn container, or on Linux, chosen per cage, a microVM under
systemd-vmspawn with a kernel of its own (ADR-019). On Linux the cages run
natively on the host (config via `nixosModules.host` in the host's NixOS
configuration). On macOS they run in
one shared NixOS microVM (microvm.nix + qemu) that exists to provide a Linux
kernel. A project is any directory under a
configured workspace root (`flake.nix` and `devShells.default` are both
optional; see ADR-021 and ADR-005) -- there are no nixcage-specific files in
projects.
The primary use case is running AI coding agents in isolation.

nixcage runs cages; it has no opinion about what is built on them. What a
dependant may use is four exported primitives and nothing else (ADR-009):
`nixcage-container enter` with the flags that parameterise a session,
`nixcage-container uid <principal>`, `nixcage-container storage ensure`, and
`nixcage exec` to reach the machine the cages are on; and the verbs over a
cage those create, `status`, `netns`, `stop`, `exec` (ADR-012), `list`
(ADR-017) and `rm`, which fabriek uses as it does the four. cageworks, which runs a
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
- `modules/store-closure.sh` -- what of the store a session without the
  daemon sees (ADR-014): a root's spelling, the closure query over the roots,
  and the read-only bind per path. A session with the daemon binds the whole
  store as before.
- `modules/principal-uid.sh` -- allocation of the uid a cage is mapped onto.
  A principal is whatever a caller wants a durable number for; nixcage promises
  only that one name always answers with one number and that none is reissued.
- `modules/declaration.sh` -- what a host declared, and what stands in for it
  where nothing was (ADR-024): one reader with two implementations, sourced by
  the CLI and by `nixcage-container` so one format has one parser. Every
  setting's undeclared value is stated in `nixcage_declaration_reset`, which
  is where a new option says what it means on a host that declared nothing.
- `modules/gitconfig.sh` -- the identity a session commits as, rendered where
  the session is, from the fields a host declared or a caller named.
- `modules/bridges.nix` -- `nixcage.bridges.<name>` (ADR-018), imported by
  both the host module and the VM module: a bridge a cage may be placed on,
  with no static ports, its address, and the two settings an empty bridge
  needs; the name refused at evaluation by the check `enter --network`
  applies. `tests/command/modules.bats` evaluates both modules for real.
- `modules/scope.sh` -- the verbs over a running cage, read from the scope
  nspawn allocates for it (ADR-012): status, the leader's namespace path,
  stop; and the cage's record (ADR-017): what enter was given, written
  under the state directory, and `list --json` joining the two. Over a
  cgroup root, a proc root and a state directory the suite can point at
  fixtures.
- `modules/exec-cage.sh` -- a command inside a running cage (ADR-012): the
  nsenter, setpriv and env words from the leader's own environment.
- `modules/veth.sh` -- the veth pair a bridge placement gets (ADR-013): the
  host end named from a hash of the cage's name, the ip words to make and
  delete it, and the argument nspawn takes; and the port's pin and
  isolation (ADR-015): the bridge-family table `nixcage` made at runtime,
  the nft words that pin the port to its address, and the bridge word that
  isolates it.
- `modules/storage.sh` -- a path given to a uid: a dataset where there is a
  pool and an ordinary directory where there is not (ADR-017 in cageworks,
  whose behaviour this inherited). Callers name paths, never datasets.
- `modules/substrate.sh` -- which substrate a cage runs on (ADR-019): a
  table over the host's declaration, the record of the first enter, the
  flag and the host's default, and the refusal naming the winner.
- `modules/vmspawn-args.sh` -- the vmspawn line and the session credential
  a microvm session is built from, assembled from the same parse as the
  nspawn line; the credential's size bound.
- `modules/microvm-session.sh` -- the host side of a microvm session: what
  is refused before boot, the watch over a boot, the status enter exits
  with, the ssh-over-vsock words `exec` and the agent forward use, and the
  asked environment kept for `exec`.
- `modules/guest.nix` -- the NixOS guest a microvm session boots, one per
  host, built by the host module from the host's own pkgs; and
  `modules/guest-session.sh`, its one unit: reads the credential, runs
  argv as the host uid on the console, leaves the status in the home,
  powers off.
- `modules/machine.sh` -- a machine (ADR-026): a long-lived microVM that is
  itself a nixcage host. Its declaration as the host module renders it, the
  vmspawn line its unit runs, the state the host reports, and the ssh words
  a verb is forwarded into it with. `nixcage-container machine
  up|down|status|exec` and `--machine` on the verbs over a cage use it.
- `modules/machine-guest.nix` -- the guest a machine boots: the session
  guest's boot with no session, nixcage's host module beside it, and its
  state on the raw disk only qemu opens. Lifecycle modelled in
  `models/machine.qnt`.
- `modules/nixcage.nix` -- the VM module (macOS path): nixcage options
  (`workspaceRoots`, `authorizedKeys`, `sshPort`, `shareProto`, `secretEnv`,
  `git.*`, `vm.*`, `principalUidRange`) and the VM base config.
- `modules/host.nix` -- the Linux host module: `workspaceRoots`, `secretEnv`,
  `git.*`, `storage.dataset`, `principalUidRange`, `microvm.*`,
  `substrate.default` and `cages.<path>.substrate`; renders
  `/etc/nixcage/config` for the CLI and `/etc/nixcage/container` for the guest,
  installs the container layer on the host. Everything it declares goes into
  one rendered file, `/etc/nixcage/declaration`, carrying a version.
- `templates/config/` -- the flake template users instantiate at
  `~/.config/nixcage` (their VM configuration; sops-nix wired in).
- `examples/project/` -- an ordinary project flake showing the devShell
  interface.
- `package.nix` -- the CLI's one definition, taking `pkgs`: the flake's
  `packages.default` and `overlays.default` both call it, so the package a
  machine gets through the overlay is the one the checks run.
- `flake.nix` -- packages nixcage, exports `nixosModules.nixcage` and
  `templates.config`, defines the dev shell and the checks.
- `docs/` -- ADRs and generated TRACKER.md.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, openssh
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats --recursive tests/
nix flake check -L                   # + the NixOS checks; CI runs all of these
nix build -L .#hostChecks.microvm    # a microVM session; needs nested KVM, not in CI
nix build -L .#hostChecks.machine    # a machine and a cage inside it; the same
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

**MicroVM substrate** (ADR-019) -- `enter --substrate microvm` on a Linux
host with `nixcage.microvm.enable`: `enter_microvm` in `container.nix`
takes over from the point the cage's uid, home and record exist. The root
share is an empty skeleton owned by the cage's first uid, the store a
read-only share whole, every other share the host uid unshifted, so the
session runs as the owner's uid by identity (not ADR-010's block). argv
and its environment go in as one credential; `init=` and the console
settings go in through `SYSTEMD_VMSPAWN_QEMU_EXTRA`, since vmspawn writes
its own `-append` and the guest's kernel parameters never reach a direct
boot. Readiness and the exit status are files the guest writes and syncs
into the home; a watch stops a guest nobody heard from within 30 s. The
scope is registered under the name escaped as a unit name (`\x2d` for a
dash), which `scope.sh` asks for beside nspawn's spellings. `exec` and the
agent are ssh over vsock with the key vmspawn made. A placement is a tap
nixcage makes under its veth name and hands to qemu. The lifecycle is
modelled in `models/microvm-session.qnt`. To debug a boot, take the line
`--print-argv` prints, replace `systemd.log_target=null` with
`journal-or-kmsg` and add `--forward-journal=<dir>`.

**Secrets** -- sops-nix in the user's config flake; age key generated on the
VM data volume at first boot; `nixcage.secretEnv` maps env vars to secret
names, injected per session by the guest script from `/run/secrets`. The
host environment is never read.

**A host that declared nothing** (ADR-023) -- with no `/etc/nixcage/config`,
`host_declared` answers false and every reader gives the undeclared answer
instead of refusing: `check_workspace_root` takes `$PWD` (refusing `/`,
`/nix`, `/nix/store`, `$HOME` itself and anything the caller does not own),
`read_container_config` yields no subjects and no dataset, and the `uid` and
`storage ensure` verbs refuse naming the option that carries what they need.
What a session is built from travels as flags over sudo, because sudo clears
the environment: `--profile`, and for a microVM `--guest` and
`--microvm-path`, plus `--git-name`/`--git-email` for the identity the module
would have rendered. Bounds come from the machine, half of each. The layer is
in what `nix run` fetches; the guest, qemu and virtiofsd are flake outputs
realised on the first microVM session and cached in `$STATE/microvm`.

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
