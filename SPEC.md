# nixcage Specification

Version: 0.1.0

## 1. Purpose

nixcage creates sandboxed, reproducible development environments for individual project directories. It combines Nix (for declarative package management) with OS-level sandboxing (for filesystem/network isolation) and direnv (for automatic environment activation). The primary use case is running untrusted or semi-trusted tools (e.g., AI coding assistants) with controlled access to the host system.

## 2. Requirements

### 2.1 Host prerequisites

| Dependency     | Required on | Purpose                                      |
| -------------- | ----------- | -------------------------------------------- |
| Nix            | All         | Package resolution, `nix-shell`, `nix-store` |
| direnv         | All         | Automatic environment loading via `.envrc`   |
| jq             | All         | JSON construction for package lists          |
| bubblewrap     | Linux       | Sandbox execution (`bwrap`)                  |
| sandbox-exec   | macOS       | Sandbox execution (Seatbelt/SBPL profiles)   |
| coreutils, sed | All         | File manipulation (bundled via Nix wrapper)  |
| systemd-run    | Linux (opt) | cgroup-based CPU/memory limits               |

### 2.2 Supported platforms

- Linux x86_64 / aarch64 (any distribution with Nix installed)
- macOS x86_64 / aarch64 (Darwin, with Seatbelt available)

Other Unix systems are rejected at startup by `detect_os()`.

## 3. CLI interface

```
nixcage <command> [args...]
```

### 3.1 Commands

| Command                | Description                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `init [dir]`           | Generate all project files in `dir` (default: `.`). Fails if `.nixcage/` already exists.           |
| `reinit [dir]`         | Remove `.nixcage/` then run `init`. Overwrites `nixcage.toml` and `.envrc`.                        |
| `destroy [dir]`        | Remove `.nixcage/`, `nixcage.toml`, and `.envrc`.                                                  |
| `shell`                | Enter the sandbox interactively. Uses `cage.command` from config if set, otherwise drops to shell. |
| `run <cmd...>`         | Run a single command inside the sandbox. Arguments are joined and passed to `nix-shell --run`.     |
| `status`               | Print current config values, detected OS, and check all dependency binaries.                       |
| `_direnv_hook`         | (Internal) Output shell code for `.envrc` to eval. Exports `NIXCAGE_*` vars, defines aliases.      |
| `help`, `--help`, `-h` | Print usage summary.                                                                               |
| `version`, `--version`, `-v` | Print `nixcage <version>`.                                                                   |

### 3.2 Project root discovery

`find_cage_root()` walks from `$PWD` upward looking for `nixcage.toml`. If not found, the process exits with an error. This applies to `shell`, `run`, and `status`. For `_direnv_hook`, the command gracefully degrades by outputting an `echo` warning instead of exiting, since its output is `eval`'d by direnv and a hard exit would break the shell.

### 3.3 Exit codes

| Code | Meaning                                                                           |
| ---- | --------------------------------------------------------------------------------- |
| 0    | Success                                                                           |
| 1    | Any error (missing config, unsupported OS, dependency not found, sandbox failure) |

The script runs under `set -euo pipefail`. Any unhandled non-zero exit or unbound variable terminates the process.

## 4. Configuration

### 4.1 File format

`nixcage.toml` at the project root. Parsed by a minimal built-in TOML parser with these limitations:

- Supports flat `[section]` headers and dot-separated nested sections (e.g., `[sandbox.filesystem]`)
- Supports string scalars (quoted or unquoted), booleans (`true`/`false` unquoted), integers, and simple single-line arrays
- Does **not** support nested tables, inline tables, multi-line arrays, or multi-line strings
- Full-line comments (`# ...`) are skipped; inline comments after quoted or unquoted scalar values are stripped. A `#` inside a quoted value is preserved (e.g., `command = "echo #tag"` keeps the `#`). Inline comments inside array values are not supported.
- Keys must match `[a-z_]+`

### 4.2 Configuration keys

All parsed values are stored in `CAGE_*` global shell variables.

#### `[sandbox]`

| Key     | Type   | Default      | Values                                | Description                              |
| ------- | ------ | ------------ | ------------------------------------- | ---------------------------------------- |
| `level` | string | `"standard"` | `"strict"`, `"standard"`, `"relaxed"` | Sandbox isolation preset (see Section 5) |

#### `[sandbox.filesystem]`

| Key         | Type     | Default | Description                                            |
| ----------- | -------- | ------- | ------------------------------------------------------ |
| `ro_bind`   | string[] | `[]`    | Extra host paths mounted read-only inside the cage     |
| `rw_bind`   | string[] | `[]`    | Extra host paths mounted read-write inside the cage    |
| `blacklist` | string[] | `[]`    | Host paths hidden (replaced with empty tmpfs on Linux) |

All paths support `~` prefix, which is expanded to `$HOME` at runtime. `ro_bind`/`rw_bind` paths must exist on the host or they are silently skipped (on both platforms). `blacklist` paths are mounted as tmpfs unconditionally on Linux.

On Linux, `ro_bind`/`rw_bind` are implemented as bwrap `--ro-bind`/`--bind` arguments.

On macOS, `ro_bind` paths are added as `(allow file-read* (subpath ...))` rules to the Seatbelt profile. `rw_bind` paths are added as `(allow file-read* file-write* (subpath ...))`. `blacklist` is not supported on macOS (Seatbelt cannot selectively deny a subpath that a parent rule already allows); a warning is logged if blacklist paths are configured.

#### `[sandbox.network]`

| Key     | Type | Default | Description                                                                 |
| ------- | ---- | ------- | --------------------------------------------------------------------------- |
| `allow` | bool | `true`  | Enable/disable network access. When `false`, overrides the level's default. |

On Linux, `allow = false` removes `--share-net` from bwrap args and adds `--unshare-net`.

On macOS, `allow = false` strips all `(allow network-outbound)` and `(allow network-inbound)` lines from the resolved Seatbelt profile, causing network operations to fall through to `(deny default)`.

#### `[sandbox.resources]`

| Key      | Type   | Default | Description                                                     |
| -------- | ------ | ------- | --------------------------------------------------------------- |
| `cpus`   | int    | `0`     | Max CPU cores. `0` = unlimited. Linux only (via `systemd-run`). |
| `memory` | string | `""`    | Max memory (e.g., `"4G"`). Empty = unlimited. Linux only.       |

Resource limits require `systemd-run` on the host. If `systemd-run` is not available, limits are silently ignored. On macOS, these settings have no effect and a warning is logged if non-default values are configured.

Implementation: when either value is non-default and `systemd-run` exists, the bwrap invocation is prefixed with `systemd-run --user --scope -q -p CPUQuota=<N>00% -p MemoryMax=<M>`.

#### `[nix]`

| Key          | Type     | Default         | Description                                  |
| ------------ | -------- | --------------- | -------------------------------------------- |
| `packages`   | string[] | `["nodejs_22"]` | Nix package attribute names from `<nixpkgs>` |
| `pure`       | bool     | `true`          | Pass `--pure` to `nix-shell`                 |
| `store_mode` | string   | `"readonly"`    | Nix store isolation strategy (see Section 6) |

Package names are serialized to JSON via `jq`, exported as `NIXCAGE_PACKAGES_JSON`, and consumed by the generated `shell.nix` which resolves `pkgs.${name}` for each entry.

#### `[cage]`

| Key               | Type     | Default                                 | Description                                                     |
| ----------------- | -------- | --------------------------------------- | --------------------------------------------------------------- |
| `command`         | string   | `""`                                    | Default command for `nixcage shell`. Empty = interactive shell. |
| `passthrough_env` | string[] | `["TERM", "LANG", "ANTHROPIC_API_KEY"]` | Host environment variables forwarded into the sandbox.          |

On Linux, passthrough is implemented via `bwrap --setenv <VAR> <VALUE>` for each variable that is non-empty on the host.

On macOS, passthrough is implemented by prepending `export VAR='<escaped_value>';` to the `bash -c` command string. Single quotes in values are escaped using the `'\''` idiom to prevent injection.

## 5. Sandbox levels

### 5.1 Level matrix

| Aspect       | `strict`                                                             | `standard`    | `relaxed`             |
| ------------ | -------------------------------------------------------------------- | ------------- | --------------------- |
| `/nix/store` | Read-only                                                            | Read-only     | Read-only             |
| Project dir  | Not mounted                                                          | Read-write    | Read-write            |
| Home (`~`)   | tmpfs (empty)                                                        | tmpfs (empty) | Read-only (real home) |
| `/tmp`       | tmpfs                                                                | tmpfs         | tmpfs                 |
| Network      | Disabled                                                             | Enabled       | Enabled               |
| System paths | `/etc/resolv.conf`, `/etc/ssl`, `/etc/static`*, `/etc/nix`, `/proc`, `/dev` (all ro) | Same          | Same                  |

### 5.2 Linux implementation (bwrap)

The generated `sandbox-linux.sh` profile defines `build_bwrap_args()` which constructs the bwrap argument array:

- **All levels**: `--unshare-pid --unshare-uts --unshare-ipc --die-with-parent`, `/nix/store` (ro-bind), system paths (`/etc/resolv.conf`, `/etc/ssl`, `/etc/static`\*, `/etc/nix`), `--proc /proc --dev /dev --tmpfs /tmp`. \*`/etc/static` is NixOS-specific and only mounted if present.
- **strict**: `--tmpfs /home --unshare-net`
- **standard**: `--tmpfs /home --share-net --bind <project_dir> <project_dir>`
- **relaxed**: `--ro-bind $HOME $HOME --share-net --bind <project_dir> <project_dir>`
- **All levels**: `--chdir <project_dir>`

After `build_bwrap_args()`, the runner applies store mode modifications, extra binds, blacklist, network override, env passthrough, resource limits, and finally invokes bwrap with the nix-shell command.

### 5.3 macOS implementation (sandbox-exec)

Three Seatbelt profiles are generated at init time as `.sb` files. Each starts with `(version 1) (deny default)` and explicitly allows required operations.

Common rules across all profiles:

- `process-exec`, `process-fork`, `signal`, `sysctl-read`, `mach-lookup`, `ipc-posix*`
- `file-read*` on: `/nix`, `/dev`, `/private/tmp`, `/usr/lib`, `/usr/share`, `/System`, `/Library/Frameworks`, `/private/var/run`, `/etc/resolv.conf`, `/private/etc/resolv.conf`
- `file-write*` on: `/private/tmp`, `/dev/null`, `/dev/tty`

Level-specific additions:

- **strict**: No network rules. No project dir access.
- **standard**: `file-read* file-write*` on `NIXCAGE_PROJECT_DIR`. `network-outbound`, `network-inbound`.
- **relaxed**: `file-read*` on `HOME_DIR`. `file-read* file-write*` on `NIXCAGE_PROJECT_DIR`. `network-outbound`, `network-inbound`.

Placeholder resolution: before invocation, `sed` replaces literal strings `NIXCAGE_PROJECT_DIR` and `HOME_DIR` with actual absolute paths. The resolved profile is written to `sandbox-macos-resolved.sb` (gitignored).

The sandbox is entered via: `sandbox-exec -f <resolved_profile> /bin/bash -c "<env_exports> cd '<project_dir>' && <nix_cmd>"`

## 6. Nix store isolation modes

All modes first resolve the nix environment on the host (`nix-shell --run "true"`) to ensure all packages exist in `/nix/store`. On Linux, the derivation path is obtained via `nix-instantiate` for use by `copy` and `isolated` store modes. On macOS, this step is skipped since those modes fall back to `readonly`.

### 6.1 `shared`

- **Linux**: `/nix/store` is ro-bind mounted (from `build_bwrap_args`). The nix daemon socket (`/nix/var/nix/daemon-socket/socket`) is bind-mounted read-write, allowing `nix-env` or `nix-build` inside the cage.
- **macOS**: No additional rules. The default profile already allows `file-read*` on `/nix`.

### 6.2 `readonly` (default)

- **Linux**: `/nix/store` is ro-bind mounted. `/nix/var` is overlaid with tmpfs, blocking daemon communication. New package installation inside the cage fails.
- **macOS**: Appends `(deny file-write* (subpath "/nix"))` to the resolved profile.

### 6.3 `copy` (Linux only)

1. Creates `.nixcage/store/` under the project directory.
2. Calls `copy_store_closure()` which runs `nix-store -qR <drv_path>` to enumerate the full runtime closure, then `cp -a` each store path into the local store (skipping already-copied paths).
3. Removes the default `/nix/store` ro-bind from bwrap args.
4. Adds `--ro-bind <local_store>/nix/store /nix/store` and `--tmpfs /nix/var`.

On macOS, this mode logs a warning and falls back to `readonly`.

### 6.4 `isolated` (Linux only)

1. Creates `.nixcage/isolated-store/` under the project directory.
2. On first run only (when `isolated-store/nix/store` does not exist), copies the full closure using the same `copy_store_closure()` mechanism.
3. Replaces the bwrap `/nix/store` bind with the isolated store, same as `copy`.

The difference from `copy`: `isolated` only populates on first run and does not update on subsequent runs, providing a frozen snapshot. `copy` re-evaluates and copies missing paths each run.

On macOS, this mode logs a warning and falls back to `readonly`.

## 7. Generated files

`nixcage init [dir]` creates the following file tree:

```
<dir>/
  nixcage.toml                          # User-editable configuration
  .envrc                                # direnv hook (evals nixcage _direnv_hook)
  .nixcage/
    .gitignore                          # Ignores resolved profiles, store dirs, logs
    shell.nix                           # Nix expression consuming NIXCAGE_PACKAGES_JSON
    profiles/
      sandbox-linux.sh                  # build_bwrap_args() function
      sandbox-macos-strict.sb           # Seatbelt SBPL template (strict)
      sandbox-macos-standard.sb         # Seatbelt SBPL template (standard)
      sandbox-macos-relaxed.sb          # Seatbelt SBPL template (relaxed)
      sandbox-macos-resolved.sb         # (runtime, gitignored) Resolved profile with actual paths
```

Runtime directories created on demand:

- `.nixcage/store/nix/store/...` (by `copy` store mode)
- `.nixcage/isolated-store/nix/store/...` (by `isolated` store mode)

### 7.1 `shell.nix`

```nix
{ pkgs ? import <nixpkgs> {} }:
let
  extraPackages = builtins.fromJSON (builtins.getEnv "NIXCAGE_PACKAGES_JSON");
  resolvedPkgs = map (name: pkgs.${name} or (throw "Unknown package: ${name}")) extraPackages;
in pkgs.mkShell {
  buildInputs = resolvedPkgs;
  shellHook = ''
    export NIXCAGE_ACTIVE=1
    export NIXCAGE_ROOT="$(pwd)"
  '';
}
```

Package names are read from the `NIXCAGE_PACKAGES_JSON` environment variable (a JSON array of strings). Each name is resolved as a top-level attribute of `pkgs`. If a name does not exist, evaluation fails with `throw`.

### 7.2 `.envrc`

```bash
if command -v nixcage &>/dev/null; then
  eval "$(nixcage _direnv_hook)"
else
  echo "[nixcage] Warning: nixcage not found in PATH. Falling back to plain nix-shell."
  use nix .nixcage/shell.nix
fi
```

Fallback: if `nixcage` is not installed, direnv loads `shell.nix` directly without sandboxing.

## 8. direnv integration

`nixcage _direnv_hook` outputs shell code that is `eval`'d by the `.envrc`:

```bash
export NIXCAGE_ACTIVE=1
export NIXCAGE_ROOT="<project_dir>"
export NIXCAGE_LEVEL="<level>"
export NIXCAGE_OS="<linux|macos>"

cage() { nixcage "$@"; }
cagerun() { nixcage run "$@"; }

echo "[nixcage] Cage active: level=<level> os=<os>"
echo "[nixcage] Use 'nixcage run <cmd>' or 'nixcage shell' to enter the sandbox"
```

The hook does **not** enter the sandbox. It only sets metadata variables and convenience aliases. Actual sandboxing occurs when `nixcage run` or `nixcage shell` is invoked.

## 9. Execution flow

### 9.1 `nixcage run <cmd>`

1. `find_cage_root()` locates `nixcage.toml` by walking up from `$PWD`.
2. `parse_config()` reads the TOML file into `CAGE_*` globals.
3. Validate `CAGE_LEVEL` is one of `strict`, `standard`, `relaxed`. Exit with error if invalid.
4. If no command arguments are provided and `CAGE_COMMAND` is non-empty, it is used as the default command.
5. `run_sandboxed()` dispatches to `run_linux()` or `run_macos()` based on `$OS`.

#### 9.1.1 Linux flow (`run_linux`)

1. Verify `bwrap` is available.
2. Source `sandbox-linux.sh` to define `build_bwrap_args()`.
3. Serialize `CAGE_PACKAGES` to JSON.
4. Pre-resolve: `NIXCAGE_PACKAGES_JSON=<json> nix-shell <shell.nix> --run "true"` to populate `/nix/store`.
5. Obtain derivation path: `NIXCAGE_PACKAGES_JSON=<json> nix-instantiate <shell.nix>`.
6. Build bwrap argument array via `build_bwrap_args()`.
7. Apply store mode modifications.
8. Append extra ro/rw binds (with tilde expansion, existence check).
9. Append blacklist paths as tmpfs mounts (with tilde expansion).
10. Apply network override if `allow = false`.
11. Build env passthrough args.
12. Optionally wrap with `systemd-run` for resource limits.
13. Build nix-shell args (with `--pure` if configured, `--run` if command given).
14. Execute: `[systemd-run ...] bwrap <bwrap_args> <env_args> nix-shell <shell.nix> [--pure] [--run <cmd>]`.

#### 9.1.2 macOS flow (`run_macos`)

1. Verify `sandbox-exec` is available.
2. Select Seatbelt profile template based on `CAGE_LEVEL`.
3. Serialize `CAGE_PACKAGES` to JSON.
4. Pre-resolve nix environment (same as Linux).
5. Apply store mode (only `shared` and `readonly` are effective; `copy`/`isolated` fall back with warning).
6. Resolve placeholder strings in the `.sb` template via `sed`, write to `sandbox-macos-resolved.sb`.
7. Append store mode deny rules if applicable.
8. Append extra ro/rw bind paths as Seatbelt rules (with tilde expansion, existence check).
9. Build env export string with single-quote escaping.
10. Apply network override if `allow = false` (strip `(allow network-*)` lines via `sed`).
11. Build nix-shell command string with proper quoting.
12. Execute: `sandbox-exec -f <resolved_profile> /bin/bash -c "<env_exports> cd '<project_dir>' && nix-shell '<shell.nix>' [--pure] [--run '<cmd>']"`.

### 9.2 `nixcage shell`

Identical to `nixcage run` but with no command arguments. If `cage.command` is set in the config, that command is used. Otherwise, `nix-shell` opens an interactive shell.

## 10. Security model

### 10.1 Threat model

nixcage is designed to limit the blast radius of tools that may:

- Read files outside the project directory (e.g., `~/.ssh`, `~/.aws`)
- Write to arbitrary locations
- Make unexpected network connections
- Consume excessive system resources

It is **not** designed to contain a determined adversary with root-level exploits. The sandbox relies on kernel-level isolation (Linux namespaces, macOS Seatbelt) which have known limitations.

### 10.2 Security boundaries

| Boundary          | Linux                            | macOS                                     |
| ----------------- | -------------------------------- | ----------------------------------------- |
| Filesystem        | Namespace + bind mounts          | Seatbelt `file-read*`/`file-write*` rules |
| Process isolation | PID namespace                    | Not available                             |
| Network           | Network namespace                | Seatbelt `network-*` rules                |
| IPC               | IPC namespace                    | Allowed (`mach-lookup`, `ipc-posix*`)     |
| Resource limits   | cgroups via systemd-run          | Not available                             |
| User namespace    | Not used (runs as invoking user) | N/A                                       |

### 10.3 Injection prevention

- macOS env passthrough escapes single quotes in variable values using the `'\''` idiom (via `escape_sq()`)
- macOS project directory path is single-quoted in the `bash -c` command string
- macOS nix-shell path and `--run` arguments are single-quoted and escaped
- Linux uses `bwrap --setenv` which does not go through shell interpretation

### 10.4 Limitations

- **macOS Seatbelt is deprecated.** Apple has not removed it but does not document or guarantee its behavior. Future macOS versions may change or remove it.
- **macOS `mach-lookup` is broadly allowed.** This permits inter-process communication via Mach ports, which is necessary for most macOS processes to function but weakens isolation.
- **No user namespace isolation.** Processes inside the cage run as the invoking user. If the sandbox is escaped, the attacker has the user's full privileges.
- **`blacklist` on macOS is ineffective.** Seatbelt cannot selectively deny a subpath when a parent path is allowed.
- **TOML parser is minimal.** Complex TOML features (nested tables, multi-line values) are not supported.

## 11. Packaging

### 11.1 Flake (`flake.nix`)

Uses [flake-parts](https://flake.parts/) for per-system outputs.

- `packages.default`: `mkDerivation` that copies `nixcage` into `$out/bin` and wraps it with runtime deps (`jq`, `coreutils`, `gnused`, `bash`, and `bubblewrap` on Linux) via `wrapProgram`.
- `devShells.default`: provides `bash`, `jq`, `shellcheck`, `direnv`, `bats`, and (on Linux) `bubblewrap`.

Nixpkgs input tracks `nixos-unstable`.

## 12. Environment variables

### 12.1 Set by nixcage

| Variable                | Set where                    | Value                         |
| ----------------------- | ---------------------------- | ----------------------------- |
| `NIXCAGE_ACTIVE`        | direnv hook + inside sandbox | `1`                           |
| `NIXCAGE_ROOT`          | direnv hook + inside sandbox | Absolute path to project root |
| `NIXCAGE_PACKAGES_JSON` | Inside sandbox               | JSON array of package names   |
| `NIXCAGE_LEVEL`         | direnv hook only             | Current sandbox level string  |
| `NIXCAGE_OS`            | direnv hook only             | `linux` or `macos`            |

### 12.2 Read by nixcage

| Variable                        | Used by          | Purpose                                          |
| ------------------------------- | ---------------- | ------------------------------------------------ |
| `HOME`                          | Runner, profiles | Home directory for relaxed mode, tilde expansion |
| `PWD`                           | `find_cage_root` | Starting directory for upward search             |
| Each entry in `passthrough_env` | Runner           | Forwarded into the sandbox if non-empty on host  |

## 13. Platform compatibility matrix

| Feature                   | Linux           | macOS                  |
| ------------------------- | --------------- | ---------------------- |
| Sandbox engine            | bwrap           | sandbox-exec           |
| PID namespace             | Yes             | No                     |
| UTS namespace             | Yes             | No                     |
| IPC namespace             | Yes             | No                     |
| Network namespace         | Yes             | Seatbelt rules         |
| Filesystem bind mounts    | Yes             | No (path-based ACL)    |
| Resource limits (CPU/mem) | systemd-run     | Not available          |
| Store mode: `shared`      | Yes             | Yes                    |
| Store mode: `readonly`    | Yes             | Yes                    |
| Store mode: `copy`        | Yes             | Falls back to readonly |
| Store mode: `isolated`    | Yes             | Falls back to readonly |
| `blacklist` paths         | tmpfs overlay   | Not effective          |
| `network.allow = false`   | `--unshare-net` | Strip allow rules      |
