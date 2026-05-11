# nixcage Specification

Version: 1.1.0

## 1. Purpose

nixcage boots a NixOS microVM per project directory and auto-enters it when the
user `cd`s into the directory. It uses [microvm.nix](https://github.com/astro/microvm.nix)
as the VM backend (cloud-hypervisor on Linux, QEMU on macOS). The primary use
case is running AI coding agents (claude-code, opencode) in full VM-level
isolation with reproducible, Nix-managed environments.

There is no process-level sandboxing. The VM boundary is the only isolation
primitive. If you need bwrap/Seatbelt-style sandboxing, use a different tool.

## 2. Requirements

### 2.1 Host prerequisites

| Dependency        | Required on | Purpose                                          |
| ----------------- | ----------- | ------------------------------------------------ |
| Nix (with flakes) | All         | Build the VM image                               |
| ssh, ssh-keygen   | All         | VM control plane                                 |
| python3 or perl   | All         | Free-port selection at `init` time               |
| KVM               | Linux       | cloud-hypervisor acceleration                    |
| Hypervisor.framework | macOS    | QEMU acceleration                                |
| bash, coreutils, grep, sed, awk, sha256sum | All | Script runtime                  |

The tool itself is a single Bash script. The Nix flake provides a `devShell`
with `bash`, `jq`, `shellcheck`, `bats`, and `openssh` for development.

### 2.2 Supported platforms

- Linux x86_64 / aarch64 (KVM required)
- macOS aarch64 / x86_64 (Hypervisor.framework required)

`detect_os()` rejects all other systems at startup.

The host architecture is auto-detected by `detect_nix_system()`:

| `uname -m`        | Guest system     |
| ----------------- | ---------------- |
| `x86_64`          | `x86_64-linux`   |
| `arm64`/`aarch64` | `aarch64-linux`  |

The guest is always Linux, regardless of host. On macOS hosts, the VM runner
itself is a Darwin-native binary (set via `microvm.vmHostPackages`).

## 3. CLI interface

```
nixcage <command> [args...]
```

### 3.1 Commands

| Command                | Description                                                                 |
| ---------------------- | --------------------------------------------------------------------------- |
| `init [dir]`           | Generate all per-project files in `dir` (default: `.`). Fails if `nixcage.vm.nix` already exists. |
| `build`                | Build the VM runner via `nix build`. First build takes 15+ minutes.         |
| `start`                | Launch the VM runner in the background, wait for SSH, inject secrets.       |
| `stop`                 | SIGTERM the VM (10s grace), then SIGKILL if needed. Removes the pid file.   |
| `shell`                | SSH into the VM. Starts the VM first if not already running.                |
| `run <cmd...>`         | Run a command inside the VM via SSH. Starts the VM first if needed.         |
| `sync`                 | Compare config hash to last build; rebuild and restart if stale, else no-op.|
| `logs`                 | `tail -f` the VM stdout/stderr log.                                         |
| `status`               | Print project path, nix system, hypervisor, share proto, ssh port, build/run state. |
| `install-hook [--remove]` | Append (or remove) the cd auto-enter hook in `~/.zshrc` or `~/.bashrc`.  |
| `destroy [dir]`        | Stop the VM, remove `nixcage.vm.nix` and `.nixcage-vm/`, prune `.gitignore` entry. |
| `_vm_hook [zsh\|bash]` | (Internal) Emit hook code to stdout for manual `eval` installation.         |
| `version`, `--version`, `-v` | Print `nixcage <version>`.                                            |
| `help`, `--help`, `-h` | Print usage summary.                                                        |

### 3.2 Project root discovery

`find_vm_root()` walks from `$PWD` upward looking for `nixcage.vm.nix`. If not
found, the process exits with an error. This applies to `build`, `start`,
`stop`, `shell`, `run`, `sync`, `logs`, and `status`. `init` and `destroy`
operate on an explicit `[dir]` argument (default `.`).

### 3.3 Exit codes

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| 0    | Success                                                                  |
| 1    | Any error (missing config, unsupported OS, VM build failure, SSH timeout, etc.) |

The script runs under `set -euo pipefail`. Any unhandled non-zero exit or
unbound variable terminates the process.

## 4. Per-project file layout

```
<project>/
  nixcage.vm.nix              # User-editable NixOS module (committed)
  .gitignore                  # Updated by init: appends ".nixcage-vm/" once
  .nixcage-vm/                # Generated state (gitignored)
    flake.nix                 # Generated VM flake (microvm + base + user config)
    flake.lock                # Created by 'nixcage build'
    config                    # SSH_PORT, SECRET_VARS, HYPERVISOR, SHARE_PROTO, NIX_SYSTEM
    id_ed25519                # SSH private key (per-project)
    id_ed25519.pub            # SSH public key (baked into VM via authorizedKeys)
    known_hosts               # Populated by ssh-keyscan after first boot
    nixcage.vm.nix            # Copy of project's nixcage.vm.nix (refreshed each build)
    result -> /nix/store/...  # VM runner symlink (after build)
    build-hash                # sha256 of nixcage.vm.nix + flake.lock at last build
    vm.pid                    # Hypervisor process PID (while running; removed on stop)
    vm.log                    # Hypervisor stdout+stderr (persists across runs)
```

`nixcage.vm.nix` is the presence signal for a nixcage project. Its existence is
what `find_vm_root()` and the shell hook detect.

### 4.1 `.nixcage-vm/config`

Flat `key=value` file, `#` comments allowed. Read by `vm_read_config()` into
`VM_*` globals.

| Key           | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| `SSH_PORT`    | Random free TCP port chosen at init time (host-side forwarded port)|
| `SECRET_VARS` | Comma-separated list of env-var names to inject (no values stored) |
| `HYPERVISOR`  | `cloud-hypervisor` (Linux) or `qemu` (macOS)                       |
| `SHARE_PROTO` | `virtiofs` (Linux) or `9p` (macOS)                                 |
| `NIX_SYSTEM`  | `x86_64-linux` or `aarch64-linux`                                  |

This file is regenerated by `nixcage init`. It is gitignored because it contains
host-specific values (port number) and is not portable across hosts.

### 4.2 `nixcage.vm.nix`

User-facing NixOS module. The init template is a stub with commented examples
showing how to add packages, adjust VM resources, and mount extra host paths.
Users own this file; nixcage never overwrites it after init.

This module is composed with `microvm.nixosModules.microvm` and
`nixcage.nixosModules.base` in the generated flake.

### 4.3 Generated VM flake (`.nixcage-vm/flake.nix`)

Generated by `cmd_init`. Pinned inputs:

- `nixpkgs` -> `github:NixOS/nixpkgs/nixos-unstable`
- `microvm` -> `github:astro/microvm.nix` (follows `nixpkgs`)
- `nixcage` -> `github:hamidr/nixcage` (follows `nixpkgs`)

Single output: `nixosConfigurations.vm`, composed from:

1. `microvm.nixosModules.microvm`
2. `nixcage.nixosModules.base` (the `vm-base.nix` module)
3. `./nixcage.vm.nix` (the user's module; refreshed on every build)
4. An inline module that sets `microvm.{hypervisor, mem, vcpu, shares, interfaces, forwardPorts}` and `users.users.nixcage.openssh.authorizedKeys.keys`.

Defaults: 2047 MB RAM, 2 vCPUs, `/workspace` share pointing at the project
directory, user-mode networking with SSH port forward `$SSH_PORT:22`.

On macOS the inline module also sets
`microvm.vmHostPackages = nixpkgs.legacyPackages.<aarch64|x86_64>-darwin` so the
runner script is a Darwin-native binary while the guest remains Linux.

## 5. Base NixOS module (`modules/vm-base.nix`)

Exported as `nixosModules.base` from the top-level flake. Applied to every
nixcage VM. Provides:

- `claude-code`, `git`, `nodejs_22`, `jq`, `curl`, `bash`, `openssh` in
  `environment.systemPackages`. `opencode` is added if present in nixpkgs.
- `services.openssh` with `PasswordAuthentication = false` and
  `PermitRootLogin = "no"`.
- `users.users.nixcage`: normal user, in `wheel`, bash login shell. The
  per-project SSH public key is added by the generated flake, not here.
- `security.sudo.wheelNeedsPassword = false` (the `nixcage` user has passwordless sudo).
- `systemd.services.nixcage-secrets`: oneshot, copies `/run/nixcage-secrets` (if
  present) to `/etc/profile.d/nixcage-secrets.sh`. Restarted by `nixcage start`
  after secrets are injected.
- `environment.loginShellInit`: `cd /workspace` when the login shell starts in `$HOME`.
- `networking.hostName = "nixcage-vm"`, `system.stateVersion = "24.11"`.

The `/workspace` mount itself is declared by the generated per-project flake
(not here) because the share protocol differs per host.

## 6. Build, start, sync

### 6.1 Build (`nixcage build`)

1. Copy `nixcage.vm.nix` into `.nixcage-vm/nixcage.vm.nix` so Nix pure
   evaluation can see it from inside the flake tree.
2. Run `nix build 'path:.#nixosConfigurations.vm.config.microvm.declaredRunner' --out-link result -L` from inside `.nixcage-vm/`.
3. Compute `sha256sum nixcage.vm.nix flake.lock | sha256sum` (hash of the
   concatenated per-file digests) and write it to `.nixcage-vm/build-hash`.

The `result` symlink points at the hypervisor runner script.

### 6.2 Start (`nixcage start`)

1. Verify `result` exists, else error.
2. Compare current config hash to `build-hash`; warn (not block) if stale.
3. Resolve runner: prefer `result/bin/microvm-run` if executable, else `result` itself.
4. Launch runner in background: `"$runner" >vm.log 2>&1 &`. Save `$!` to `vm.pid`.
5. `vm_wait_for_ssh()`: poll `ssh ... true` every 2s until success. Timeout
   120s on Linux, 300s on macOS. If the runner process dies first, abort with
   pointer to `vm.log`.
   - `known_hosts` is truncated before polling because the VM regenerates host
     keys each boot. `StrictHostKeyChecking=accept-new` accepts and persists
     the new host key on first successful connection.
6. `vm_inject_secrets()`: see Section 7.

### 6.3 Stop (`nixcage stop`)

`kill $pid`, wait up to 10s, then `kill -9`. Remove `vm.pid`.

### 6.4 Sync (`nixcage sync`)

Compute current `vm_compute_build_hash` and compare to `build-hash`. If equal:
no-op. If different: `cmd_build`; if VM was running, `cmd_stop` then `cmd_start`.

`sync` does not flag the case where `result` is missing entirely; that is what
`start` checks.

## 7. Secrets injection

At init time, `vm_detect_ai_keys()` scans the host environment for these
variable names and records the ones currently set:

- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `OPENCODE_API_KEY`
- `GITHUB_TOKEN`

The comma-separated list of names (not values) is written to `SECRET_VARS=` in
`.nixcage-vm/config`. The list can be edited by hand to add or remove names.

At `start` time, `vm_inject_secrets()`:

1. Reads `SECRET_VARS` from config.
2. For each name with a non-empty value on the host, builds an
   `export VAR='<value>'` line (single-quote escaped via `'\''`).
3. Pipes the result via SSH into the VM:
   `sudo tee /run/nixcage-secrets >/dev/null && sudo chmod 600 /run/nixcage-secrets && sudo systemctl restart nixcage-secrets`.
4. The `nixcage-secrets` systemd service then copies the tmpfs file to
   `/etc/profile.d/nixcage-secrets.sh` (mode 0600) so every login shell sources it.

`/run` is tmpfs, so the source file never reaches the guest disk. The
`/etc/profile.d/` copy is persistent within the running VM but lives on
microvm.nix's writable overlay, which is itself ephemeral if the VM is
configured for stateless runs.

## 8. SSH transport

All control-plane communication uses SSH on `127.0.0.1:$SSH_PORT` with the
per-project ed25519 key. `vm_ssh()` always passes:

- `-p $VM_SSH_PORT`
- `-i .nixcage-vm/id_ed25519`
- `-o UserKnownHostsFile=.nixcage-vm/known_hosts`
- `-o StrictHostKeyChecking=yes`
- `-o ConnectTimeout=5`
- `-o BatchMode=yes`

Login user is always `nixcage`. The host key is accepted on first connection
(`accept-new`) by `vm_wait_for_ssh()` and verified strictly thereafter.

## 9. Shell hook (auto-enter)

`nixcage install-hook` appends a delimited block to the user's shell rc file
(`~/.zshrc` for zsh, `~/.bashrc` for bash). The block is bounded by
`# nixcage-hook-begin` and `# nixcage-hook-end` so `--remove` can excise it
cleanly. Re-running `install-hook` is idempotent.

### 9.1 zsh hook

Uses `chpwd` via `add-zsh-hook`. Fires on every directory change.

### 9.2 bash hook

Uses `PROMPT_COMMAND`. Tracks the last `$PWD` to fire only on directory change.

### 9.3 Hook logic (both shells)

```
if [[ -f "$PWD/nixcage.vm.nix" ]] && [[ -z "${NIXCAGE_VM_ACTIVE:-}" ]]; then
  export NIXCAGE_VM_ACTIVE=1
  nixcage shell
  unset NIXCAGE_VM_ACTIVE
fi
```

`NIXCAGE_VM_ACTIVE` is a re-entry guard. Without it, exiting the VM SSH session
would land back in the host shell which would immediately re-invoke
`nixcage shell` again.

### 9.4 Manual installation

`nixcage _vm_hook [zsh|bash]` emits the hook body to stdout. Users who manage
their dotfiles externally can `eval "$(nixcage _vm_hook zsh)"` instead of
letting nixcage edit their rc file.

## 10. Destroy

`nixcage destroy [dir]`:

1. If the VM is running, `cmd_stop`.
2. Remove `nixcage.vm.nix` and the entire `.nixcage-vm/` directory.
3. Remove the `.nixcage-vm/` line from `.gitignore` if it is present as an
   exact match. Other gitignore content is left untouched.

The `--keep-config` and `--keep-keys` style flags do not exist; destroy is
all-or-nothing.

## 11. Security model

### 11.1 Threat model

nixcage limits the blast radius of tools that may:

- Read files outside the project directory (`~/.ssh`, `~/.aws`, browser profiles)
- Write to arbitrary host locations
- Make unexpected outbound connections from the host's network identity
- Consume host resources

The VM boundary is enforced by the hypervisor (cloud-hypervisor or QEMU/HVF).
The guest sees only `/workspace` (the project directory) plus whatever extra
host paths the user explicitly adds to `microvm.shares` in `nixcage.vm.nix`.

### 11.2 Boundaries

| Boundary       | Mechanism                                                                  |
| -------------- | -------------------------------------------------------------------------- |
| Filesystem     | Only declared `microvm.shares` are visible to the guest                    |
| Process        | Hypervisor-level isolation (separate kernel)                               |
| Network        | User-mode networking; outbound only (no host listen sockets except SSH forward) |
| Resources      | `microvm.mem`, `microvm.vcpu` cap RAM and CPU                              |
| Secrets        | Injected via tmpfs over SSH; values never written to host disk by nixcage  |

### 11.3 Known limitations

- **Trust in microvm.nix and the hypervisor.** A guest escape in
  cloud-hypervisor/QEMU/HVF defeats the boundary.
- **`/workspace` is read-write.** A malicious tool inside the VM can corrupt or
  exfiltrate anything in the project directory. nixcage does not protect the
  project against itself.
- **No network egress filtering.** If the user wants no outbound traffic from
  the VM, they must add `networking.firewall` rules to `nixcage.vm.nix`.
- **Extra shares are user-declared.** If the user adds `~/.ssh` as a share to
  let `git` push, that ring is broken on purpose.
- **`nixcage` user has passwordless sudo inside the VM.** This is for
  convenience inside the guest, not a defense.
- **No user namespace, seccomp, or capability filtering on the host.** nixcage
  does not call bwrap, sandbox-exec, or firejail. Its only host-side primitive
  is "don't share filesystems we didn't ask to share."

## 12. Packaging

### 12.1 Flake (`flake.nix`)

Uses [flake-parts](https://flake.parts/) for per-system outputs.

- `packages.default`: `mkDerivation` that installs the `nixcage` script into
  `$out/bin` and `wrapProgram`s it with `PATH` prefixed by `jq`, `coreutils`,
  `gnused`, `bash`, `openssh`. `nix`, `ssh-keygen`, and `python3`/`perl` are
  expected to come from the host environment, not the wrapper.
- `nixosModules.base`: re-exports `modules/vm-base.nix`.
- `overlays.default`: exposes `pkgs.nixcage` for downstream nixpkgs overlays.
- `devShells.default`: `bash`, `jq`, `shellcheck`, `bats` (with
  `bats-support` and `bats-assert`), `openssh`. `BATS_LIB_PATH` is exported
  so the test helpers resolve without further setup.

Supported `systems`: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`. Nixpkgs input tracks `nixos-unstable`.

## 13. Environment variables

### 13.1 Set by nixcage

| Variable             | Scope            | Value                                       |
| -------------------- | ---------------- | ------------------------------------------- |
| `NIXCAGE_VM_ACTIVE`  | Host shell hook  | `1` while inside a `nixcage shell` session  |
| Each `SECRET_VARS` entry | Inside VM    | Forwarded value, sourced by login shells    |

### 13.2 Read by nixcage

| Variable                            | Used by             | Purpose                                    |
| ----------------------------------- | ------------------- | ------------------------------------------ |
| `PWD`                               | `find_vm_root`      | Walk-up search start                       |
| `HOME`                              | `cmd_install_hook`  | Locate `~/.zshrc` / `~/.bashrc`            |
| `SHELL`                             | `cmd_install_hook`  | Pick zsh vs bash hook block                |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENCODE_API_KEY`, `GITHUB_TOKEN` | `vm_detect_ai_keys` (init), `vm_inject_secrets` (start) | Auto-detect and forward |
| Each name in `SECRET_VARS`          | `vm_inject_secrets` | Read value from host env, push to VM       |

## 14. Platform differences

| Feature           | Linux              | macOS                              |
| ----------------- | ------------------ | ---------------------------------- |
| Hypervisor        | cloud-hypervisor   | qemu                               |
| Filesystem share  | virtiofs           | 9p (virtiofsd is Linux-only)       |
| VM runner binary  | Linux              | Darwin-native (`vmHostPackages`)   |
| SSH wait timeout  | 120s               | 300s (slower QEMU boot)            |
| Guest system      | Linux              | Linux                              |

All other behavior is identical across platforms.
