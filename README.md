# nixcage

One systemd-nspawn container per project, driven by the project's own
`devShells.default` -- no nixcage files in the project, a container boundary
between projects. On Linux the containers run natively on the host. On macOS,
which has no containers, they run inside one shared NixOS microVM that exists
purely to provide a Linux kernel (and adds VM-level isolation from the host).

## How it works

```
nixcage enter                 (from any flake dir under a workspace root)
     |
     +-- VM not running? --> boot the shared VM (qemu, microvm.nix)
     |
     v
SSH into the VM
     |
     v
+---------------[VM boundary]----------------+
|                                            |
|  /nix/store        VM-owned, never the     |
|                    host store              |
|  ~/Src             workspace roots,        |
|                    mounted once            |
|                                            |
|  +------[container: this project]-------+  |
|  |                                      |  |
|  |  /workspace  <- only this project    |  |
|  |  /root       <- persistent home      |  |
|  |  /nix/store  <- read-only bind       |  |
|  |                                      |  |
|  |  nix develop   (your devShell)       |  |
|  +--------------------------------------+  |
|                                            |
+--------------------------------------------+
```

The VM boots once and serves every project. Each `nixcage enter` runs
`nix develop` inside a systemd-nspawn container that sees only its own project
directory, its own persistent home, and the VM's Nix store read-only. The first
enter per project builds the devShell inside the VM; later enters hit the cache.

## Install

```bash
nix profile install github:hamidr/nixcage
```

## Configuration on Linux

Containers run on the host; there is no VM. Import the host module in your
NixOS configuration and rebuild:

```nix
# flake input: nixcage.url = "github:hamidr/nixcage";
imports = [ inputs.nixcage.nixosModules.host ];

nixcage = {
  workspaceRoots = [ "/home/me/Src" ];
  ## Env vars from this host's sops-nix secrets, per container session.
  # secretEnv.ANTHROPIC_API_KEY = "anthropic";
};
```

`nixos-rebuild switch` applies it; the CLI is just `enter`, `rm`, and
`status` (`rebuild`/`down` are macOS-only -- the host owns the lifecycle).
Containers use the host store read-only plus the host nix-daemon.

## Configuration on macOS

The VM is configured by a Nix flake you own. Create it from the template:

```bash
nix flake new -t github:hamidr/nixcage ~/.config/nixcage
```

Edit it like any NixOS configuration. The nixcage options:

```nix
nixcage = {
  ## Only flake directories under these roots can be entered.
  workspaceRoots = [ "/home/me/Src" ];

  ## The key printed by 'nixcage status' on first run.
  authorizedKeys = [ "ssh-ed25519 AAAA..." ];

  ## macOS hosts need 9p (virtiofsd is Linux-only).
  # shareProto = "9p";

  ## Environment variables injected into every container session,
  ## resolved from sops secrets inside the VM.
  # secretEnv.ANTHROPIC_API_KEY = "anthropic";

  # vm = { cpus = 8; mem = 8192; diskSize = 40960; };
};
```

Anything else NixOS supports is fair game -- it is your VM. Apply changes with
`nixcage rebuild` (this restarts the VM and interrupts running sessions).

The CLI finds the flake at `~/.config/nixcage`; override with
`--flake <ref>` or `NIXCAGE_FLAKE`. Multi-machine setups export one
configuration per host: `nixosConfigurations."nixcage-<hostname>"` is
preferred over the shared `nixosConfigurations.nixcage`, so your dotfiles
flake can serve a macOS laptop and a NixOS desktop from one repo.

## Projects

A project is any flake directory under a workspace root. There is no
`nixcage init` and no nixcage file in the repo -- `devShells.default` is the
entire interface. Want claude-code in a project? Put it in that project's
devShell (see `examples/project/`). nixcage installs nothing into containers.

## Commands

| Command | Description |
|---|---|
| `nixcage enter [-- cmd]` | Enter this project's container (auto-starts the VM); with a command, run it non-interactively |
| `nixcage down` | Stop the VM |
| `nixcage rebuild` | Rebuild from the config flake and restart the VM |
| `nixcage rm [name]` | Delete a project's container and persistent home |
| `nixcage status` | VM state, containers, age public key |

## Secrets

Secrets go through [sops-nix](https://github.com/Mic92/sops-nix), declared in
your config flake; the host environment is never read.

1. Boot the VM once; an age key is generated on its data volume and never
   leaves it. `nixcage status` prints the public key.
2. Add that key to `.sops.yaml` next to your config flake and encrypt a
   `secrets.yaml` with `sops`.
3. Declare the secret and its mapping in the config flake:

```nix
sops.defaultSopsFile = ./secrets.yaml;
sops.secrets.anthropic = { };
nixcage.secretEnv.ANTHROPIC_API_KEY = "anthropic";
```

4. `nixcage rebuild`. Every container session now has the variable set.

Interactive logins work too: container homes persist, so `claude login` done
once inside a container survives restarts.

## Platform notes

| | Linux | macOS |
|---|---|---|
| Containers run | on the host | in a shared VM |
| Host isolation | container boundary (nspawn) | VM boundary + container |
| Nix store | host store, shared | VM-owned store |
| Hypervisor | -- | qemu (Apple HVF) |
| Secrets | host sops-nix | VM sops-nix + age key |
| Config | `nixosModules.host` in your NixOS config | VM config flake |

The container environment is always Linux; on macOS, macOS-native binaries do
not exist inside the VM.

### macOS: Linux builder setup

`nixcage rebuild` compiles a NixOS system, which requires building
`aarch64-linux` derivations. macOS needs a Linux builder for that:

```nix
## nix-darwin
nix.linux-builder.enable = true;
```

or, without nix-darwin, keep `nix run nixpkgs#darwin.linux-builder` running in
another terminal during the build.

## Migrating from 1.x

1.x gave every project its own VM configured by `nixcage.vm.nix`. That model is
gone. In each old project: stop the VM, delete `nixcage.vm.nix` and
`.nixcage-vm/`, and drop the `.nixcage-vm/` line from `.gitignore`. Remove the
shell hook block from your `~/.zshrc` / `~/.bashrc` -- 2.x has no hook. Then
set up the config flake as above.

## License

GPLv3
