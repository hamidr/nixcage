# nixcage

Sandboxed Nix environments with direnv auto-activation. Cross-platform: **bwrap** on Linux, **sandbox-exec** on macOS.

Built for running tools like [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in isolated project directories.

## How it works

```
┌─────────────────────────────────────────────────┐
│  You cd into a project directory                │
│       ↓                                         │
│  direnv detects .envrc → runs nixcage hook      │
│       ↓                                         │
│  nixcage reads nixcage.toml config              │
│       ↓                                         │
│  You run: nixcage run <cmd>                     │
│       ↓                                         │
│  ┌─── Linux ───────┐  ┌─── macOS ────────────┐  │
│  │ bwrap           │  │ sandbox-exec         │  │
│  │ + namespaces    │  │ + Seatbelt profiles  │  │
│  │ + cgroups (opt) │  │                      │  │
│  └────────┬────────┘  └────────┬─────────────┘  │
│           ↓                     ↓               │
│         nix-shell --pure (packages from config) │
│           ↓                                     │
│         Your command runs in the sandbox        │
└─────────────────────────────────────────────────┘
```

## Install

```bash
# Flake
nix profile install github:you/nixcage

# Or clone + install locally
git clone https://github.com/you/nixcage.git
cd nixcage
nix profile install .
```

### Dependencies

| Tool             | Required   | Install                                                                        |
| ---------------- | ---------- | ------------------------------------------------------------------------------ |
| **Nix**          | ✅         | `sh <(curl -L https://nixos.org/nix/install)`                                  |
| **direnv**       | ✅         | `nix-env -iA nixpkgs.direnv` + [shell hook](https://direnv.net/docs/hook.html) |
| **jq**           | ✅         | Bundled when installed via Nix; otherwise `nix-env -iA nixpkgs.jq`             |
| **bubblewrap**   | Linux only | Bundled when installed via Nix; otherwise `nix-env -iA nixpkgs.bubblewrap`     |
| **sandbox-exec** | macOS only | Built-in (ships with macOS)                                                    |

## Quick start

```bash
# 1. Initialize a project
cd ~/my-project
nixcage init

# 2. Edit the config
$EDITOR nixcage.toml

# 3. Allow direnv
direnv allow

# 4. Run Claude Code sandboxed
nixcage run npx @anthropic-ai/claude-code

# Or enter an interactive sandboxed shell
nixcage shell
```

## Configuration — `nixcage.toml`

```toml
[sandbox]
# "strict"   — no network, tmpfs home, minimal access
# "standard" — project dir writable, network allowed
# "relaxed"  — home readable, project writable, network allowed
level = "standard"

[sandbox.filesystem]
ro_bind = ["/data/models"]       # extra read-only paths
rw_bind = ["/tmp/shared"]        # extra read-write paths
blacklist = ["/home/user/.ssh"]   # paths to hide (~ is expanded)

[sandbox.network]
allow = true

[sandbox.resources]
cpus = 4       # max CPU cores (Linux only, via systemd-run)
memory = "4G"  # max RAM (Linux only)

[nix]
packages = ["nodejs_22"]
pure = true
store_mode = "readonly"   # shared | readonly | copy | isolated

[cage]
command = ""                     # default command (empty = shell)
passthrough_env = ["TERM", "LANG", "ANTHROPIC_API_KEY"]
```

## Commands

| Command                 | Description                             |
| ----------------------- | --------------------------------------- |
| `nixcage init [dir]`    | Set up a new cage                       |
| `nixcage reinit [dir]`  | Destroy and re-initialize               |
| `nixcage destroy [dir]` | Remove all nixcage files                |
| `nixcage shell`         | Enter interactive sandboxed shell       |
| `nixcage run <cmd>`     | Run a command inside the sandbox        |
| `nixcage status`        | Show config, OS, and check dependencies |

## Nix store isolation

By default, `nix-shell` reads and writes your host's `/nix/store`. nixcage gives you control over this via `store_mode` in `nixcage.toml`:

| Mode       | Reads host store?    | Writes host store? | Speed             | Isolation      | Platform   |
| ---------- | -------------------- | ------------------ | ----------------- | -------------- | ---------- |
| `shared`   | ✅                   | ✅                 | Fastest           | None           | All        |
| `readonly` | ✅ (for cached pkgs) | ❌                 | Fast              | Good — default | All        |
| `copy`     | First run only       | ❌ (local copy)    | Medium            | Strong         | Linux only |
| `isolated` | ❌                   | ❌                 | Slowest first run | Complete       | Linux only |

```toml
[nix]
store_mode = "readonly"   # recommended balance
```

How it works: nixcage resolves packages on the host _before_ entering the sandbox, then mounts the store read-only (or a copy) inside the cage. The sandboxed process can use cached packages but can't install new ones or pollute your store.

> **Note:** `copy` and `isolated` modes require Linux (bwrap bind mounts). On macOS, they fall back to `readonly` with a warning.

## Sandbox levels explained

### `strict`

- Filesystem: only `/nix/store` (read-only), `/tmp` (tmpfs), project dir (not mounted)
- Network: **disabled**
- Home: tmpfs (empty)
- Use case: auditing untrusted code

### `standard` (default)

- Filesystem: `/nix/store` (ro), project dir (read-write)
- Network: **enabled**
- Home: tmpfs (empty)
- Use case: running Claude Code on a project

### `relaxed`

- Filesystem: `/nix/store` (ro), home (read-only), project dir (read-write)
- Network: **enabled**
- Home: your real home, but read-only
- Use case: tools that need to read ~/.config, ~/.gitconfig, etc.

## Claude Code example

```bash
# Set up a project for Claude Code
mkdir ~/ai-project && cd ~/ai-project
nixcage init

# Configure for Claude Code
cat > nixcage.toml <<'EOF'
[sandbox]
level = "standard"

[sandbox.network]
allow = true

[nix]
packages = ["nodejs_22", "git"]
pure = true
store_mode = "readonly"

[cage]
passthrough_env = ["TERM", "LANG", "ANTHROPIC_API_KEY"]
EOF

direnv allow
nixcage run npx @anthropic-ai/claude-code
```

## Platform differences

| Feature              | Linux                      | macOS                            |
| -------------------- | -------------------------- | -------------------------------- |
| Sandbox engine       | bubblewrap (bwrap)         | sandbox-exec (Seatbelt)          |
| PID isolation        | ✅ namespaces              | ❌ not available                 |
| Network isolation    | ✅ `--unshare-net`         | ✅ sandbox profile               |
| Filesystem isolation | ✅ bind mounts             | ✅ Seatbelt rules                |
| Resource limits      | ✅ cgroups via systemd-run | ❌ not available                 |
| Store modes          | All four modes             | `shared` and `readonly` only     |

## How it integrates with direnv

When you `cd` into a nixcage project:

1. direnv sees `.envrc`
2. `.envrc` calls `nixcage _direnv_hook`
3. The hook exports `NIXCAGE_ACTIVE=1`, `NIXCAGE_ROOT`, etc.
4. It creates `cage` and `cagerun` shell aliases
5. You use `nixcage run` or `nixcage shell` to enter the sandbox

Note: **direnv itself does not sandbox anything** — it just auto-loads the environment. The actual isolation happens when you invoke `nixcage run` or `nixcage shell`.

## License

GPLv3
