# nixcage

NixOS microVM environments for AI coding agents. Enter a project directory and your
terminal switches into a full NixOS VM -- isolated at the kernel level, with
claude-code and opencode pre-installed, driven entirely by a Nix flake you control.

## How it works

```
cd myproject
     |
     v
shell hook detects nixcage.vm.nix
     |
     v
nixcage shell
     |
     +-- VM already running? -----> SSH in (~50ms)
     |
     +-- not running? -----------> nixcage start
                                        |
                                        v
                              fork hypervisor process
                              (cloud-hypervisor on Linux,
                               qemu on macOS)
                                        |
                                   boots NixOS VM
                                        |
                              +----[VM boundary]-----+
                              |                      |
                              |  /workspace          |  <- your project dir
                              |  /nix/store (ro)     |  <- shared host store
                              |  claude-code         |
                              |  opencode            |
                              |  + your packages     |
                              |                      |
                              +----------------------+
                                        |
                                   SSH session opens
                                   drops into /workspace
```

The host `/nix/store` is shared read-only across all VMs -- packages built once are
reused everywhere. Only `/workspace` (your project directory) crosses the VM
boundary as a live read-write mount.

## Install

```bash
nix profile install github:hamidr/nixcage
```

Or from a local clone:

```bash
git clone https://github.com/hamidr/nixcage.git
cd nixcage && nix profile install .
```

## Requirements

| Tool | Notes |
|---|---|
| Nix (flakes enabled) | `sh <(curl -L https://nixos.org/nix/install)` |
| openssh | Bundled when installed via Nix |
| cloud-hypervisor | Linux only; bundled via Nix |
| qemu | macOS only; bundled via Nix |
| Linux builder (macOS only) | Required to build NixOS VM images on macOS (see below) |

## Quick start

```bash
cd ~/myproject

nixcage init               # generates nixcage.vm.nix + .nixcage-vm/
nixcage build              # builds the VM image (~15 min first run)
nixcage install-hook       # adds auto-enter hook to ~/.zshrc or ~/.bashrc

# reload your shell, then:
cd ~/myproject             # hook fires, VM starts, SSH session opens
myproject $ claude         # claude-code is pre-installed
myproject $ exit           # back on host; VM keeps running

nixcage stop               # shut down the VM
```

## Configuration -- `nixcage.vm.nix`

The only file you edit. A standard NixOS module committed to your project:

```nix
{ pkgs, ... }: {
  ## Add project packages
  environment.systemPackages = with pkgs; [
    python3
    rustup
    postgresql
  ];

  ## Adjust resources (defaults: 2 GB RAM, 2 vCPUs)
  microvm.mem  = 4096;
  microvm.vcpu = 4;

  ## Mount extra host paths
  ## proto: "virtiofs" on Linux, "9p" on macOS
  microvm.shares = [{
    tag        = "home-ssh";
    source     = "/home/me/.ssh";
    mountPoint = "/home/nixcage/.ssh";
    proto      = "virtiofs";
  }];
}
```

AI tools (claude-code, opencode), SSH, the nixcage user, and the `/workspace` mount
are all provided by the base layer -- you do not declare them.

## Commands

| Command | Description |
|---|---|
| `nixcage init [dir]` | Generate `nixcage.vm.nix` and `.nixcage-vm/` |
| `nixcage build` | Build the VM image (run once after init or after flake updates) |
| `nixcage start` | Start the VM in the background |
| `nixcage stop` | Stop the VM |
| `nixcage shell` | Enter an interactive VM shell (auto-starts if needed) |
| `nixcage run <cmd>` | Run a single command in the VM |
| `nixcage sync` | Rebuild and restart if `nixcage.vm.nix` changed |
| `nixcage logs` | Tail the hypervisor log |
| `nixcage status` | Show built / running / SSH-reachable state |
| `nixcage install-hook` | Add auto-enter hook to `~/.zshrc` or `~/.bashrc` |
| `nixcage destroy [dir]` | Remove all nixcage files |

## Secrets

`nixcage init` scans the host environment for known AI keys
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENCODE_API_KEY`) and records their
names in `.nixcage-vm/config`. When the VM starts, their values are piped into
`/run/nixcage-secrets` (tmpfs -- never flushed to disk) via SSH and made available
to every login shell. Values never enter the Nix store.

To change which keys are injected, edit `SECRET_VARS=` in `.nixcage-vm/config`.

## After a fresh clone

`.nixcage-vm/` is fully gitignored. Each collaborator runs:

```bash
nixcage init    # generates a new key pair and selects a free SSH port
nixcage build   # builds the VM (subsequent builds are fast -- Nix cache)
```

## Platform notes

| | Linux | macOS |
|---|---|---|
| Hypervisor | cloud-hypervisor (KVM) | qemu (TCG / Apple HVF) |
| Filesystem share | VirtioFS | 9p |
| VM boot time | ~500ms | ~2-3s |
| Guest OS | NixOS (x86_64 or aarch64) | NixOS (aarch64 on Apple Silicon) |
| macOS-native binaries in VM | no | no |

The VM guest is always Linux/NixOS regardless of host OS. macOS-native binaries are
not available inside the VM. This is the trade-off for uniform behavior across
platforms.

### macOS: Linux builder setup

`nixcage build` compiles a NixOS system, which requires building `aarch64-linux`
derivations. macOS cannot do this natively -- you need a Linux builder. This is a
small background NixOS VM that Nix uses as a remote build machine.

**nix-darwin (recommended):**

Add to your nix-darwin configuration:

```nix
nix.linux-builder.enable = true;
```

Then rebuild: `darwin-rebuild switch --flake .`

**Without nix-darwin:**

```bash
# Start the builder (runs a QEMU VM in the foreground)
nix run nixpkgs#darwin.linux-builder
```

Leave it running in a separate terminal while you run `nixcage build`.

Once the builder is available, `nixcage build` works transparently -- Nix
offloads Linux builds to it automatically.

## License

GPLv3
