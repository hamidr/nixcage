# nixcage

Run an AI coding agent on your own machine without handing it your machine.

## Why

Coding agents such as Claude Code want to run commands, edit files and
install things, and they want to do it fast, without asking. Given the run
of your laptop, that means your ssh keys, your cloud tokens, your other
repositories, your home directory. Given nothing, they are useless.

nixcage gives each project a cage: a small Linux world in which the agent
sees that one project, a persistent home of its own, and the tools the
project declares, and nothing else. It cannot see other projects, your
files, or your keys. Commits still get signed, because your ssh-agent is
forwarded in as a socket while the key stays outside. Secrets the agent
needs (an API token, say) reach it as environment variables from your
existing sops-nix setup, never from your shell.

## What you get

- **Nothing to add to a project.** A project is any flake directory under a
  workspace root you name. The project's own `devShells.default` is the
  environment inside the cage, so what the agent gets is what the project
  already says it needs. No Dockerfile, no image, no nixcage file in the
  repo.
- **One command.** `cd` into a project and `nixcage enter`; you are in the
  cage, in the devShell, in the project. `nixcage enter -- claude` runs the
  agent straight away. The home persists, so `claude login` is done once.
- **A boundary you choose.** By default a cage is a systemd-nspawn
  container: fast to enter, sharing the host's kernel and Nix store. On a
  Linux host you can instead give a cage a microVM with a kernel of its own,
  for a tool you trust less or one that needs its own kernel; same command,
  one flag, decided once per cage. On macOS every cage runs inside one
  shared Linux VM, which is a boundary of its own.
- **Something to build on.** nixcage runs cages and has no opinion about
  what runs in them. A tool that wants several agents sharing one
  repository, each as its own user on its own private network, gets four
  primitives and nothing else; see "Building on nixcage" below.

## How it works

On Linux, `nixcage enter` runs the container on the host directly. On macOS
there are no containers, so the same container runs inside a shared NixOS
microVM reached over SSH:

```
nixcage enter                 (from any flake dir under a workspace root)
     |
     +-- Linux: run the container on the host
     |
     +-- macOS: VM not running? --> boot the shared VM (qemu, microvm.nix)
     |          then SSH into it
     v
+----------[host, or the VM on macOS]--------+
|                                            |
|  /nix/store        the host's store on     |
|                    Linux, the VM's on      |
|                    macOS                   |
|  ~/Src             workspace roots         |
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

Each `nixcage enter` runs `nix develop` inside a systemd-nspawn container that
sees only its own project directory, its own persistent home, and the Nix store
read-only. The first enter per project builds the devShell; later enters hit the
cache. On macOS the VM boots once and serves every project.

### A cage with its own kernel

On a Linux host with `nixcage.microvm.enable = true`, a cage may run in a
microVM instead: `nixcage enter --substrate microvm`. The choice is made at
the cage's first enter (or declared in the host config) and then fixed; a
flag against it is refused naming what fixed it. Everything else is the
same `enter`: the project at `/workspace`, the persistent home (at
`/home/nixcage`, since the guest owns `/root`), the store read-only, your
ssh-agent forwarded, secrets injected, `exec`, `status`, `stop`, `list`.
What differs: a kernel boundary toward the host and toward other cages, no
nix daemon and no builds inside (the session sees the store and cannot add
to it, so put the toolchain in the devShell or realise it elsewhere), a
boot of about seven seconds instead of a tenth, and memory reserved rather
than shared. `--disk 2G` adds a persistent image at `/var/lib` for what
virtiofs is too slow for. This is for a tool you trust less than the rest,
or one that needs a kernel of its own (eBPF, mount namespaces, modules).
See `docs/ADR-019-a-cage-may-run-in-a-microvm-behind-the-same-enter.md`.

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
  ## Let a cage run in a microVM of its own (needs /dev/kvm and systemd 261).
  # microvm.enable = true;
  # principalUidRange = { base = 700000; size = 64; };
  ## Fix a cage's substrate from here, over its record and the flag.
  # cages."/home/me/Src/untrusted".substrate = "microvm";
  ## What a cage runs on when nothing closer decides.
  # substrate.default = "nspawn";
};
```

`nixos-rebuild switch` applies it; the CLI is just `enter`, `rm`, and
`status` (plus `version`; `rebuild`/`down` are macOS-only -- the host owns the lifecycle).
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

  ## 9p is the default and the only protocol that works on a macOS host;
  ## virtiofs needs virtiofsd, which is Linux-only.
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
| `nixcage enter [--substrate nspawn\|microvm] [--disk SIZE] [-- cmd]` | Enter this project's cage (on macOS, auto-starts the VM); with a command, run it non-interactively. The substrate is fixed at the first enter; `--disk` gives a microVM a persistent image at `/var/lib` |
| `nixcage exec [--tty] [--agent] -- cmd` | Run a command as root where the cages are: on this host on Linux, inside the VM on macOS |
| `nixcage rm [name]` | Delete a project's container and persistent home |
| `nixcage status` | Configuration in use, containers, and on macOS the VM state and age public key |
| `nixcage down` | Stop the VM (macOS only) |
| `nixcage rebuild` | Rebuild from the config flake and restart the VM (macOS only) |
| `nixcage version` | Print the version |

## Building on nixcage

nixcage runs cages and has no opinion about what runs in them. A tool that
wants more than one person entering one project -- several named workers
sharing a repository, say -- pins nixcage as a flake input and uses four
exported primitives, which are the whole interface (ADR-009):

| Primitive | What it gives |
|---|---|
| `nixcage-container enter [--uid n] [--user name] [--subject name] [--home path] [--shell name] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--no-agent] [--network BRIDGE:ADDR/PREFIX\|ns:PATH] [--dns none\|ADDR] [--no-nix-daemon] [--memory SIZE] [--cpus N] [--substrate nspawn\|microvm] [--disk SIZE] [--print-argv] <name> <project> [cmd]` | A session built out of what you asked for, bounded on its scope when asked; with `--print-argv`, the nspawn or vmspawn line it would run, one word per line, and no session. On a microVM cage (ADR-019) `--memory` and `--cpus` are the guest's own, `--shell` and `ns:` are refused, and `--network` places a tap nixcage makes |
| `nixcage-container uid <principal> [<subject>]` | A durable uid for a name, never reissued |
| `nixcage-container storage ensure <path> <uid> [quota]` | That path owned by that uid, bounded where it can be |
| `nixcage-container status <name>`, `netns <name>`, `stop <name>` | A running cage from its scope: its leader and cgroup, the namespace path `enter --network ns:` takes (`none` for a microVM, which has no namespace on the host), and an end to it (ADR-012) |
| `nixcage-container list [--json]` | Every cage entered and not removed; with `--json`, one object per cage with what enter was given (uid, subject, placement, roots) and, while it runs, its scope and leader (ADR-017) |
| `nixcage-container exec [--subject <name>] <name> [-- cmd]` | A command inside a running cage: its leader's namespaces, its HOME and PATH, as cage root or as a declared subject (ADR-012); over vsock ssh into a microVM cage, as the session's uid with the session's environment (ADR-019) |
| `nixcage exec [--tty] [--agent] -- <cmd>` | A way to reach the other three from your own machine |

You name paths and principals; nixcage names datasets and numbers. Set
`nixcage.principalUidRange` to allow allocation at all, and
`nixcage.principalSubjects` when one cage needs to hold processes that should
not be able to reach each other: a principal is then allocated a contiguous
block, one uid per subject beside cage root, and a session may run as one of
them (ADR-010). Declaring no subjects is a block of one and a session that is
cage root, which is what ADR-004 built.
A bridge a cage is placed on with `enter --network` is declared as
`nixcage.bridges.<name> = { address; prefix; }` on either module (ADR-018):
nixcage renders the bridge with no static ports, its address, and the two
settings an empty bridge needs to be usable before its first cage arrives;
what a cage may reach on that address is your firewall's to open.
[cageworks](https://github.com/hamidr/cageworks) is built on exactly this.

## Secrets

On Linux, secrets come from the host's own sops-nix setup: declare
`nixcage.secretEnv` next to your existing `sops.secrets` and rebuild. The steps
below are the macOS path, where the VM owns the key.

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

## Store growth

The VM owns its store, and every project's devShell lands in the same writable
overlay, so it only grows. The VM therefore collects garbage weekly, keeping
30 days, and hardlinks duplicate paths. Override any of it in your config
flake:

```nix
nix.gc.dates = "monthly";
nix.gc.automatic = false;
```

Collection between sessions drops devShell closures, since `nix develop` holds
only a temporary root; the next `nixcage enter` for that project fetches them
again. On Linux there is no VM and no separate store: the host's own gc policy
applies unchanged.

## Platform notes

| | Linux | macOS |
|---|---|---|
| Containers run | on the host | in a shared VM |
| Host isolation | container boundary (nspawn), or a microVM per cage with `--substrate microvm` | VM boundary + container |
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
shell hook block from your `~/.zshrc` / `~/.bashrc` -- 3.x has no hook. Then
set up the host module (Linux) or the config flake (macOS) as above.

Nothing carries over from a 1.x VM: the containers, their persistent homes, and
the age key are all created fresh.

## License

GPLv3
