# Measurements

Written by `scripts/measure`, which is the only thing that should write it.
Every number an ADR asserts belongs here with the command that produced it,
the date it ran, and the host it ran on. A number quoted anywhere else without
one of these behind it is a number nobody has checked.

- Measured for: `x86_64-linux`
- Measured on: `aarch64-darwin`
- Date: 2026-09-23
- Revision: `511a621`

## What a microVM session realises the first time it is asked for

ADR-023 decision 6 turns on these: they are what an nspawn session would pay
for and never use, which is why they are flake outputs rather than part of
what the CLI carries.

```
nix build --dry-run .#packages.x86_64-linux.guest
these 204 derivations will be built:
these 301 paths will be fetched (302.2 MiB download, 949.9 MiB unpacked):
```

| Output | Closure against cache.nixos.org |
| --- | --- |
| `qemu` | 1450 MiB |
| `virtiofsd` | 44 MiB |
| `openssh` | 74 MiB |

Each is `nix path-info -S --store https://cache.nixos.org` over the path
`nix eval --raw .#packages.x86_64-linux.<output>` answers with. A slimmer qemu is
not a saving unless nixcage caches it: an override of `qemu_kvm` is absent
from cache.nixos.org, so asking for one makes the caller compile qemu rather
than fetch it.

## What `nix run github:hamidr/nixcage` fetches

ADR-023 decision 6 says the layer travels with the CLI and the microVM's
parts do not. This is that claim as a number.

```
nix build --dry-run .#packages.x86_64-linux.default
these 4 derivations will be built:
these 236 paths will be fetched (212.5 MiB download, 939.9 MiB unpacked):
```

Read as a closure size this would answer "not in the cache": nixcage
publishes no binary cache of its own, so its four derivations -- the CLI, the
guest script, the container profile and the wrapper -- are built by whoever
runs it, and only their dependencies are fetched. That is also why the guest
above says 204 derivations rather than a download: they are unit files, /etc
sets and a toplevel, not compilers, but they are still work the first caller
does.

## Not measured here

A macOS host can query a binary cache for any system, which is why the
closures above are real. It cannot build a Linux derivation or boot a Linux
kernel, so these remain open, with the command each one wants:

| Claim | Where it is asserted | Command |
| --- | --- | --- |
| What the guest's own 204 derivations cost in time | ADR-023 Consequences | `time nix build .#packages.x86_64-linux.guest` |
| That building the guest against the host's revision leaves only nixcage's own derivations | ADR-023 decision 9 | `nix build --dry-run .#packages.x86_64-linux.guest --override-input nixpkgs github:NixOS/nixpkgs/$(nixos-version --json \| jq -r .nixpkgsRevision)` |
| A microVM cage boots in about seven seconds | ADR-019, README | `time nixcage enter --substrate microvm -- true` |
| An nspawn cage enters in about a tenth of a second | README | `time nixcage enter -- true` |
| What the guest's 302.2 MiB is made of, and whether it can be trimmed | ADR-023 Consequences | `nix path-info -Sh --store https://cache.nixos.org --closure-size` over the guest, sorted |

Run `scripts/measure` on a Linux host and this section shrinks.
