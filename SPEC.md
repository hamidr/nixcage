# nixcage Specification

Version: 5.1.4

## 1. Purpose

nixcage runs one cage per project: a systemd-nspawn container, or on Linux,
chosen per cage, a microVM under systemd-vmspawn with a kernel of its own
(ADR-019). A project is any directory under a configured workspace root, and
on a host that declared none, the directory the caller is standing in
(ADR-023). `flake.nix` and `devShells.default` are both optional (ADR-021,
ADR-005): `nixcage enter` runs the project's devShell where it declares one,
direnv where it has an `.envrc`, and the base container shell otherwise.

On Linux the containers run natively on the host (container boundary between
projects and toward the host). On macOS, which has no containers, they run in
one shared NixOS microVM ([microvm.nix](https://github.com/astro/microvm.nix),
qemu) that provides the Linux kernel and adds a VM boundary toward the host.
The primary use case is running AI coding agents in isolation. See
`docs/ADR-002-shared-vm-project-containers.md` and
`docs/ADR-003-native-containers-on-linux.md` for the rationale.

## 2. Requirements

### 2.1 Host prerequisites

| Dependency        | Required on | Purpose                          |
| ----------------- | ----------- | -------------------------------- |
| Nix (with flakes) | All         | Realise the layer, the guest and the VM image |
| systemd           | Linux       | nspawn, the cage's scope, and vmspawn for a microVM (261 or newer) |
| sudo              | Linux       | Every session is privileged where the cages are |
| ssh, ssh-keygen   | macOS       | VM control plane                 |
| KVM               | Linux       | qemu acceleration, and a microVM cage at all |
| Hypervisor.framework | macOS    | qemu acceleration                |
| Linux builder     | macOS       | Build aarch64-linux derivations  |
| bash, coreutils, grep, sed, awk, jq | All | Script runtime   |

NixOS is not required on Linux: a host that has declared nothing runs a cage
from what the CLI carries (section 3.0.1).

The tool itself is a single Bash script. The flake provides a `devShell` with
`bash`, `jq`, `shellcheck`, `bats`, and `openssh` for development.

### 2.2 Supported platforms

- Linux x86_64 / aarch64 (KVM required)
- macOS aarch64 / x86_64 (Hypervisor.framework required)

The guest is always Linux. On macOS hosts the runner is a Darwin-native qemu
(`microvm.vmHostPackages`), set in the user's config flake template.

## 3. Configuration

### 3.0 Linux: the host module

On Linux there is no VM and no config flake. `nixosModules.host` is imported
into the host's NixOS configuration; it installs `nixcage-container` and the
container profile, and renders one file, `/etc/nixcage/declaration` (override
path with `NIXCAGE_HOST_CONFIG`, used by tests), which both the CLI and the
guest script read through `modules/declaration.sh` (ADR-024). It carries
`DECLARATION_VERSION`, `HOST_PLATFORM`, `WORKSPACE_ROOTS`,
`SUBSTRATE_DEFAULT`, `CAGE_SUBSTRATES`, `BOUNDS_DEFAULT`, `CAGE_BOUNDS`,
`MICROVM_GUEST`, `PRINCIPAL_UID_BASE`, `PRINCIPAL_UID_SIZE`,
`PRINCIPAL_SUBJECTS`, `STORAGE_DATASET`, `SECRET_ENV` and the `GIT_*` fields.
A declaration whose version this nixcage does not read stops the session
rather than reading as absent; where it is missing entirely, the files a
nixcage before ADR-024 rendered (`/etc/nixcage/config`,
`/etc/nixcage/container`, `/etc/nixcage/secret-env`,
`/etc/nixcage/gitconfig`) are read instead and the session says so, until one
release from now. With `nixcage.microvm.enable` the module also builds the
guest a microVM cage boots, from the host's own pkgs, and names it in the
declaration; the substrate options are `nixcage.substrate.default` (`nspawn`)
and `nixcage.cages.<path>.substrate`, and they are the host module's alone.
Containers bind
the host store read-only and build through the host nix-daemon; `secretEnv`
resolves against the host's own sops-nix `/run/secrets`. The CLI commands on
Linux are `enter`, `rm`, and `status`, executing `sudo nixcage-container`
locally; `rebuild` and `down` fail pointing at `nixos-rebuild`. `NIXCAGE_OS`
overrides OS detection for tests only.

### 3.0.1 Linux: a host that declared nothing

With no `/etc/nixcage/config`, every reader gives the undeclared answer rather
than refusing (ADR-023). The cage is `$PWD`; `/`, `/nix`, `/nix/store`, the
invoking user's home itself and any directory that user does not own are
refused, since there is no declared root to catch a mistyped `cd`. The session
is built from what this nixcage carries, named across sudo because sudo clears
the environment: `--profile`, and for a microVM `--guest` and
`--microvm-path`, plus `--git-name`/`--git-email` for the identity the module
would have rendered, read from the invoking user's own `git config`. A
declared host passes none of them and refuses them. Bounds are half the
machine's memory and cores, announced. The guest, qemu where the machine has
no `qemu-system-<arch>` of its own, virtiofsd and openssh are realised on the
first microVM session, cached in `$STATE/microvm`, with the cost printed and
confirmed first. `nixcage-container uid` and `storage ensure` refuse, naming
`nixcage.principalUidRange` and `nixcage.storage.dataset`: a uid that is never
reissued and a dataset the pool is mounted at are promises only a host can
make. There are no secrets, no declared subjects and no bridges.

Sections 3.1-3.3 below apply to macOS.

### 3.1 The config flake

All configuration lives in a Nix flake the user owns. The CLI locates it by,
in order: the `--flake <ref>` global option, the `NIXCAGE_FLAKE` environment
variable, the default `~/.config/nixcage`. The flake exports one or more VM
configurations importing `microvm.nixosModules.microvm` and
`nixcage.nixosModules.nixcage`; the CLI picks
`nixosConfigurations."nixcage-<hostname -s>"` when it exists and falls back
to `nixosConfigurations.nixcage`, so a single flake can serve several
machines (the nixos-rebuild hostname convention). A starter is scaffolded with
`nix flake new -t github:hamidr/nixcage ~/.config/nixcage`.

### 3.2 nixcage module options

| Option                  | Type            | Default    | Meaning                                    |
| ----------------------- | --------------- | ---------- | ------------------------------------------ |
| `nixcage.workspaceRoots`| list of str     | (required) | Host dirs shared into the VM at identical paths |
| `nixcage.authorizedKeys`| list of str     | (required) | SSH public keys accepted by the VM         |
| `nixcage.sshPort`       | port            | 22022      | Host port forwarded to guest 22            |
| `nixcage.shareProto`    | virtiofs or 9p  | virtiofs   | 9p on macOS hosts                          |
| `nixcage.secretEnv`     | attrs of str    | `{}`       | Env var -> sops secret name per session    |
| `nixcage.vm.cpus`       | positive int    | 4          | vCPUs                                      |
| `nixcage.vm.mem`        | positive int    | 4096       | MiB RAM                                    |
| `nixcage.vm.diskSize`   | positive int    | 20480      | MiB per persistent volume                  |
| `nixcage.bridges.<name>`| `{ address; prefix; }` | `{}` | A bridge a cage may be placed on: no static ports, the address, `ConfigureWithoutCarrier`, `net.ipv4.ip_nonlocal_bind` (ADR-018); on the host module too |
| `nixcage.microvm.enable` | bool | `false` | Host module only: build the microVM guest and put qemu, virtiofsd and ssh on the container script's path (ADR-019) |
| `nixcage.microvm.guestModules` | list of modules | `[]` | Host module only: NixOS modules added to the guest |
| `nixcage.substrate.default` | `nspawn` or `microvm` | `nspawn` | Host module only: what a cage runs on when neither declaration, record nor flag says |
| `nixcage.cages.<path>.substrate` | `nspawn` or `microvm` | -- | Host module only: fixes a cage's substrate by project path, over its record and the flag |
| `nixcage.cages.<path>.binds` | list of str | `[ ]` | Host module only: paths this cage always has, `SRC:DST` or `SRC:DST:ro`, added to whatever the session asks for; two binds on one destination are refused (ADR-025) |
| `nixcage.bounds` | `{ memory; cpus; }` | `null` | What a cage may use: `MemoryMax=`/`CPUQuota=` on nspawn, the guest's own RAM and vCPUs on a microVM (ADR-022) |
| `nixcage.cages.<path>.bounds` | `{ memory; cpus; }` | `null` | The same for one cage, over the default and under the session's `--memory`/`--cpus` |
| `nixcage.git.userName`, `.userEmail`, `.signing.enable` | str, str, bool | `""`, `""`, `true` | The identity a session commits as, rendered to `/etc/nixcage/gitconfig`; signing goes through the forwarded agent (ADR-008) |
| `nixcage.principalUidRange` | `{ base; size; }` | `{ 700000; 64; }` | The block `nixcage-container uid` allocates from, monotonically, never reissuing (ADR-004, ADR-010) |
| `nixcage.principalSubjects` | list of str | `[ ]` | The subjects every cage has besides its root (ADR-010) |
| `nixcage.containerPackages` | list of package | `[ ]` | What every session's userland carries on top of the minimal one; `enter` takes binds and environment, never packages |
| `nixcage.storage.dataset` | null or str | `null` | Host module only: the pool `storage ensure` makes datasets in; without one it makes directories (ADR-017) |
| `nixcage.microvm.guest` | read-only | -- | Host module only: the guest as evaluated, built from the host's own pkgs |

The VM module renders the same one declaration inside the VM.

Everything must be evaluable at build time; the CLI holds no configuration of
its own. Values the CLI needs at runtime (`sshPort`, `workspaceRoots`) are
cached to `$STATE/cache` during `rebuild` so `enter` never runs `nix eval`.

### 3.3 Machine state (not configuration)

`~/.local/state/nixcage/` (respects `XDG_STATE_HOME`):

```
id_ed25519{,.pub}   SSH keypair, generated on first start; public key must be
                    listed in nixcage.authorizedKeys
known_hosts         cleared on each VM start, filled by accept-new
result              symlink to the built microvm runner
cache               SSH_PORT=..., WORKSPACE_ROOTS=a:b (written by rebuild)
microvm             GUEST=..., PATH=... -- what an undeclared host realised
                    for a microVM session, reused until the store loses it
vm.pid, vm.log      hypervisor process
virtiofsd.pid/.log  virtiofs daemons (Linux)
```

## 4. CLI interface

```
nixcage [--flake <ref>] <command> [args...]
```

| Command            | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `enter [--memory <size>] [--cpus <n>] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--shell <name>] [--no-agent] [--print-argv] [--substrate nspawn\|microvm] [--disk <size>] [-- cmd...]`| Enter this project's cage; auto-builds and auto-starts the VM on macOS. With a command: non-interactive `nix develop --command`. The flags are handed to `nixcage-container` as they are, in either spelling (`--substrate microvm` or `--substrate=microvm`); `--substrate` needs `nspawn` or `microvm` and `--disk` a size such as `2G`, both checked here because the alternative is booting a VM before refusing. The options that parameterise a session on behalf of a dependant (`--uid`, `--user`, `--subject`, `--home`, `--network`, `--dns`, `--store-root`, `--no-nix-daemon`) are refused by name and reached with `exec`, and a flag nixcage does not have is refused rather than run as the session's command. |
| `exec [--tty] [--agent] -- <cmd...>`| Run argv as root where the cages are: on this machine on Linux, inside the VM over its SSH on macOS. How a dependant reaches `nixcage-container` without knowing this machine's SSH key, port or state layout (ADR-009). Argv is handed over as it is, with one exception: a first word of exactly `nixcage-container` on a Linux host that declared nothing becomes the layer the CLI carries, since there is no such name on any path there. |
| `down`             | Stop the VM.                                                       |
| `rebuild`          | `nix build` the runner from the config flake, refresh the cache, restart the VM if running (interrupts all sessions). |
| `list [--json]`    | What cages this machine has, with what each was given (ADR-017): name, substrate, whether it runs, and the uid it is mapped onto. `--json` hands the records over untouched, one object per line, including `declaredBinds` and whether the session that wrote each was declared. |
| `rm [name]`        | Delete a container and its persistent home; confirms first. Without a name, resolves the current project. |
| `status`           | Config flake, built/running/SSH state, container list, age public key. |
| `version`, `help`  | Metadata.                                                          |

`enter` validation order: the path is under a workspace root (from
`/etc/nixcage/config` on Linux, the cache on macOS, where errors point at
`rebuild` when it is absent), or, where nothing was declared, is a directory
the caller may cage (section 3.0.1); then VM liveness. A project needs no
`flake.nix` to be entered (ADR-021). Both `enter cmd...` and
`enter -- cmd...` are accepted.

## 5. VM architecture

- **Store**: the VM owns its store. The system closure ships read-only in the
  VM image; builds land in a writable overlay (`microvm.writableStoreOverlay`)
  backed by the persistent volume `nixcage-store.img`. The host store is never
  shared into the guest.
- **Data volume**: `nixcage-data.img` mounted at `/var/lib/nixcage` holds the
  age key, container skeletons, and per-project homes.
- **Workspace roots**: each root is a microvm share mounted at its identical
  absolute path, so host and guest agree on project paths.
- **Network**: user-mode NAT; guest SSH reachable via `forwardPorts` on
  `nixcage.sshPort` (this is why the hypervisor is qemu -- microvm.nix
  supports `forwardPorts` only with qemu user-mode networking).
- **Users**: SSH lands on the `nixcage` user (wheel, passwordless sudo);
  container operations run through `sudo nixcage-container`.

## 6. Containers

`nixcage-container` is a Nix-built script owning every nspawn and vmspawn
mechanic, shared unchanged by the host module and the VM module. On Linux the
CLI runs it locally through sudo -- the one a module installed, or the one the
CLI itself carries where nothing was declared; on macOS it only ever calls it
over SSH inside the VM.

A cage may also have binds its caller did not ask for, where the host
declared `nixcage.cages.<path>.binds` (ADR-025). They come first on the line,
go through the same checks, and appear in the cage's record as
`declaredBinds`, so what a session carries is distinguishable from what it
asked for.

A `--bind` source is resolved where the cage runs. On Linux that is the host,
so any host path works. On macOS it is the VM, which is shared only the
workspace roots, so a source outside them is not there to bind.

- `enter <name> <project> [cmd...]`: creates `/var/lib/nixcage/homes/<name>`
  and a throwaway per-session rootfs skeleton (nspawn locks its directory
  tree, so concurrent sessions of one project each get their own), then runs
  `systemd-nspawn --register=no` with:
  - `--bind-ro=/nix/store`, `--bind-ro=/nix/var/nix/db`,
    `--bind=/nix/var/nix/daemon-socket` -- containers build through the VM's
    nix-daemon (`NIX_REMOTE=daemon`), sharing one store;
  - `--bind=<project>:/workspace`, `--bind=<home>:/root`;
  - `--setenv` for each `nixcage.secretEnv` pair, values read from
    `/run/secrets/<name>`;
  - `PATH` from a minimal container profile (bash, coreutils, nix, git,
    cacert) linked at `/etc/nixcage/profile`;
  - command `nix develop` (interactive) or `nix develop --command ...`.
- `enter --network <bridge>:<address>/<prefix> ...`: the cage sends as that
  address and no other, and reaches the bridge's own address and no other
  port (ADR-015). The pin and the two rules live in a bridge-family nftables
  table named `nixcage`, made by `nixcage-container` at runtime and declared
  to no NixOS module, so `nft list ruleset` shows a table the host's
  configuration does not mention: it is nixcage's. A caller that wants two
  cages to talk runs a service on the bridge that both reach. Such a cage
  resolves nothing unless `--dns <address>` names a resolver it can reach
  (ADR-016): its `/etc/resolv.conf` is empty by default, one `nameserver`
  line when told; a session in the host's namespace keeps the host's file.
- `list`: names under `/var/lib/nixcage/containers`; `list --json`: one
  JSON object per name, the `placement` record `enter` wrote there (name,
  uid, subject, bridge and address or netns, roots, each only when given)
  and, while the cage runs, its scope's cgroup path and leader pid
  (ADR-017). The record is nixcage's: the next `enter` overwrites it, `rm`
  removes it.
- `rm <name>`: removes the container directory, home and disk image.
- `enter --substrate microvm ...` (Linux, ADR-019): the session boots the
  host's guest under `systemd-vmspawn` (261 or newer, `/dev/kvm`) instead of
  nspawn. The substrate is resolved as declaration, then the record of the
  first enter, then the flag, then the host's default; a flag that loses is
  refused naming the winner. The root share is an empty skeleton owned by the
  cage's first uid; the store is a read-only share whole; the project, the
  home (at `/home/<subject>`, `/home/nixcage` with none) and every `--bind`
  are shares as the host uid, so the session runs as the project owner's uid
  by identity. argv, its environment (secrets resolved on the host) and the
  placement go in as one credential the guest's session unit reads, bounded
  at 32768 bytes; the unit marks itself ready and leaves argv's status in the
  home, and the host reports that status, 124 when the guest was not ready
  within 30 s, 255 when it ended without one. `--memory` and `--cpus` bound
  the guest itself; `--shell` and `--network ns:` are refused; `--network`
  places a tap nixcage makes; `--disk <size>` attaches a persistent image at
  `/var/lib`, made once and attached to every later session; the agent
  arrives as a remote socket forward over vsock ssh. `status`, `stop` and
  `list` read the scope as for nspawn (registered under the name escaped as
  a unit name); `netns` answers `none`; `exec` is ssh over vsock as the
  session's uid with the session's environment.

Container names are `sanitized-basename-<8-char sha256 of abs path>`,
computed on the host (`container_name_for`).

## 7. Secrets

sops-nix only; the host environment is never read. The config flake imports
`sops-nix.nixosModules.sops` with `sops.age.keyFile =
"/var/lib/nixcage/age.key"`. The nixcage module generates that key on first
boot (a oneshot service on the data volume; sops-nix's own `generateKey`
only runs once secrets exist, too late to bootstrap). The key never leaves
the VM;
`nixcage status` prints the public key (via `age-keygen -y`) for `.sops.yaml`.
Decrypted secrets appear under `/run/secrets` (tmpfs) and reach container
sessions only through `nixcage.secretEnv`. Interactive credentials (e.g.
`claude login`) persist in the container home instead.

## 8. Testing

`shellcheck nixcage modules/*.sh` and `bats --recursive tests/` must pass.
Unit tests cover the shell modules directly (name derivation, cache parsing,
root validation, binds, bounds, scopes, vmspawn arguments); command tests
cover dispatch and pre-VM validation with `sudo`, `nix`, `git` and
`nixos-version` stubbed on `PATH`. The guest script is validated by
`writeShellApplication`'s built-in shellcheck when it is built.

What the bats suite does not do is boot a cage: every privileged path is
asserted against the words it would run, never against a running one. That is
what the NixOS checks are for: `checks.<linux>.cage` runs two machines, one
with the host module and one with nothing but the CLI, entering real cages on
each and reading the records they leave, and `checks.<linux>.primitives` runs
the sequence a dependant performs -- a uid for a principal, storage given to
that uid, a session that runs as it, and `exec` back to the host. It is a Linux virtual machine, so it
runs where a Linux builder is (`nix build .#checks.x86_64-linux.cage`) and not
on a macOS host with none.
