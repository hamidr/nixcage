# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that creates sandboxed Nix environments with direnv auto-activation. It uses **bubblewrap (bwrap)** on Linux and **sandbox-exec (Seatbelt)** on macOS. The primary use case is running tools like Claude Code in isolated project directories.

## Repository layout

- `nixcage` — the entire tool: a single self-contained Bash script (~860 lines). All commands, config parsing, and sandbox logic live here.
- `flake.nix` — Nix flake (using flake-parts) that defines the package derivation and dev shell
- `.githooks/pre-commit` — shared pre-commit hook (shellcheck + bats tests)

## Development

### Enter the dev shell

```bash
nix develop   # provides bash, jq, shellcheck, direnv (+ bwrap on Linux)
```

### Lint & test

```bash
shellcheck nixcage
bats --recursive tests/
```

There is no build step — the script runs directly. A shared pre-commit hook (`.githooks/pre-commit`) runs both shellcheck and bats before every commit. Entering `nix develop` auto-configures `core.hooksPath` via the dev shell's `shellHook`.

### Run locally without installing

```bash
bash nixcage help
bash nixcage init /tmp/test-project
```

## Architecture

The script follows a command-dispatch pattern: `main()` at the bottom dispatches to `cmd_*` functions.

### Key subsystems

1. **Config parser** (`parse_config`) — minimal TOML parser that reads `nixcage.toml` into `CAGE_*` global variables. Only handles flat keys and simple arrays; does not support nested tables or inline tables.

2. **Sandbox runners** — platform-specific functions that build sandbox arguments:
   - `run_linux()` — builds bwrap argument arrays from config (namespaces, bind mounts, network). Sources the generated `sandbox-linux.sh` profile for `build_bwrap_args()`.
   - `run_macos()` — resolves placeholders (`NIXCAGE_PROJECT_DIR`, `HOME_DIR`) in `.sb` Seatbelt profiles via sed, then calls `sandbox-exec`.
   - Both resolve nix packages on the host *before* entering the sandbox, then mount `/nix/store` inside.
   - Both protect config files (`nixcage.toml`, `.envrc`, `.nixcage/`) as read-only inside the sandbox. The `.nixcage/local/` directory remains writable for nix state.

3. **Store isolation** (`store_mode`) — four modes: `shared`, `readonly`, `copy`, `isolated`. Each mode adjusts how `/nix/store` is mounted/copied. The `copy` and `isolated` modes create local store directories under `.nixcage/`.

4. **direnv hook** (`cmd_direnv_hook`) — outputs shell code that exports `NIXCAGE_*` env vars and defines `cage`/`cagerun` aliases. Called from the generated `.envrc`.

5. **Init** (`cmd_init`) — generates all per-project files: `nixcage.toml`, `.envrc`, `.nixcage/shell.nix`, `.nixcage/profiles/` (three macOS `.sb` profiles + one Linux `.sh` profile).

### Platform branching

`detect_os()` echoes `"linux"` or `"macos"`; captured at top-level as `OS="$(detect_os)"`. `run_sandboxed()` dispatches to the appropriate runner. Resource limits (cgroups via `systemd-run`) are Linux-only. Store modes `copy` and `isolated` are Linux-only; on macOS they fall back to `readonly`.

## Conventions

- All config variables use the `CAGE_` prefix as globals.
- Sandbox profiles are generated at `init` time into `.nixcage/profiles/`, not shipped as separate source files.
- The resolved macOS profile (`sandbox-macos-resolved.sb`) is gitignored; the templates use literal placeholders.

## macOS Seatbelt profiles

The three `.sb` profiles (strict, standard, relaxed) use `(deny default)` and selectively allow operations. Beyond the obvious permissions (`process-exec`, `process-fork`, `file-read*`, `file-write*`), the following are required for `sandbox-exec -f profile /bin/bash -c "..."` to work at all:

| Permission | Why |
|---|---|
| `process-exec-interpreter` | Shebang script execution (without it, only direct binaries work) |
| `file-ioctl` | Terminal I/O operations (ioctl on `/dev/tty`); omitting causes silent abort |
| `(literal "/")` in `file-read*` | Root directory read for path traversal — many UNIX tools fail without this |

References: Apple Sandbox Guide v1.0, Chromium `seatbelt_sandbox_design.md`, OpenAI Codex `macos-seatbelt.ts`.
