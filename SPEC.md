# nixcage Specification

Version: 2.0.0

## 1. Purpose

nixcage runs one shared NixOS microVM per user and machine, with one
systemd-nspawn container per project inside it. A project is any flake
directory with a `devShells.default` located under a configured workspace
root; `nixcage enter` runs that devShell inside the project's container. The
VM backend is [microvm.nix](https://github.com/astro/microvm.nix) (qemu on
both platforms). The primary use case is running AI coding agents in VM-level
isolation from the host, with a container boundary between projects.

There is no process-level sandboxing on the host. The VM boundary isolates
everything from the host; the container boundary isolates projects from each
other. See `docs/ADR-002-shared-vm-project-containers.md` for the rationale.

## 2. Requirements

### 2.1 Host prerequisites

| Dependency        | Required on | Purpose                          |
| ----------------- | ----------- | -------------------------------- |
| Nix (with flakes) | All         | Build the VM image               |
| ssh, ssh-keygen   | All         | VM control plane                 |
| KVM               | Linux       | qemu acceleration                |
| Hypervisor.framework | macOS    | qemu acceleration                |
| Linux builder     | macOS       | Build aarch64-linux derivations  |
| bash, coreutils, grep, sed, awk, jq | All | Script runtime   |

The tool itself is a single Bash script. The flake provides a `devShell` with
`bash`, `jq`, `shellcheck`, `bats`, and `openssh` for development.

### 2.2 Supported platforms

- Linux x86_64 / aarch64 (KVM required)
- macOS aarch64 / x86_64 (Hypervisor.framework required)

The guest is always Linux. On macOS hosts the runner is a Darwin-native qemu
(`microvm.vmHostPackages`), set in the user's config flake template.

## 3. Configuration

### 3.1 The config flake

All configuration lives in a Nix flake the user owns. The CLI locates it by,
in order: the `--flake <ref>` global option, the `NIXCAGE_FLAKE` environment
variable, the default `~/.config/nixcage`. The flake must export
`nixosConfigurations.nixcage` importing `microvm.nixosModules.microvm` and
`nixcage.nixosModules.nixcage`. A starter is scaffolded with
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
vm.pid, vm.log      hypervisor process
virtiofsd.pid/.log  virtiofs daemons (Linux)
```

## 4. CLI interface

```
nixcage [--flake <ref>] <command> [args...]
```

| Command            | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `enter [-- cmd...]`| Enter this project's container; auto-builds and auto-starts the VM. With a command: non-interactive `nix develop --command`. |
| `down`             | Stop the VM.                                                       |
| `rebuild`          | `nix build` the runner from the config flake, refresh the cache, restart the VM if running (interrupts all sessions). |
| `rm [name]`        | Delete a container and its persistent home; confirms first. Without a name, resolves the current project. |
| `status`           | Config flake, built/running/SSH state, container list, age public key. |
| `version`, `help`  | Metadata.                                                          |

`enter` validation order: `flake.nix` present, path under a workspace root
(from the cache; errors point at `rebuild` when absent), then VM liveness.
Both `enter cmd...` and `enter -- cmd...` are accepted.

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

`nixcage-container` is a Nix-built script inside the VM (part of the nixcage
module); the host CLI only ever calls it over SSH.

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
- `list`: names under `/var/lib/nixcage/containers`.
- `rm <name>`: removes the container directory and home.

Container names are `sanitized-basename-<8-char sha256 of abs path>`,
computed on the host (`container_name_for`).

## 7. Secrets

sops-nix only; the host environment is never read. The config flake imports
`sops-nix.nixosModules.sops` with `sops.age.keyFile =
"/var/lib/nixcage/age.key"` and `sops.age.generateKey = true`. The key is
created on first boot on the data volume and never leaves the VM;
`nixcage status` prints the public key (via `age-keygen -y`) for `.sops.yaml`.
Decrypted secrets appear under `/run/secrets` (tmpfs) and reach container
sessions only through `nixcage.secretEnv`. Interactive credentials (e.g.
`claude login`) persist in the container home instead.

## 8. Testing

`shellcheck nixcage` and `bats --recursive tests/` must pass. Unit tests cover
the pure helpers (name derivation, cache parsing, root validation); command
tests cover dispatch and pre-VM validation, mocked at the SSH boundary. The
guest script is validated by `writeShellApplication`'s built-in shellcheck at
VM build time.
