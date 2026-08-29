---
id: ADR-003
title: Containers run natively on Linux; the VM becomes a macOS kernel shim
status: proposed
date: 2026-08-29
status_date: 2026-08-29
summary: Linux hosts run project nspawn containers directly; the shared VM remains only where a Linux kernel is missing
depends_on: [ADR-002]
supersedes: []
superseded_by: []
---

## Context

ADR-002 runs one shared VM per machine with an nspawn container per project.
Re-examining why the VM exists: macOS has no containers, so a Linux kernel
must be provided; on a NixOS host the kernel and systemd-nspawn are already
there. On Linux the VM adds a duplicated Nix store, VM boot and memory
overhead, and an SSH hop, while the layer doing the per-project work -- the
container -- is native to the host.

ADR-001 rejected process-level isolation wholesale because a container escape
compromises the host. That blanket rejection is revisited here for Linux
specifically: the accepted trade is that host-versus-agent isolation on Linux
rests on the container boundary alone.

## Decision

The container layer is the product; the VM is a shim that exists only to
provide a Linux kernel where the host lacks one.

**1. One container semantics on both platforms.** A project is a flake
directory with `devShells.default` under a workspace root. Each project gets a
plain systemd-nspawn container (no user namespaces), a persistent home, and
`nix develop` in `/workspace`, driven by the same `nixcage-container` script
and the same name derivation everywhere.

**2. Linux: containers on the host.** A new `nixosModules.host` module is
imported into the host's NixOS configuration. It installs `nixcage-container`
and the container profile, declares `nixcage.workspaceRoots` and
`nixcage.secretEnv`, and renders `/etc/nixcage/config` for the CLI.
Containers use the host store read-only plus the host nix-daemon socket, so
nothing is duplicated; state lives in `/var/lib/nixcage`. `secretEnv` maps
environment variables to the host's sops-nix secrets under `/run/secrets`.
The CLI on Linux is `enter`, `rm`, and `status`, executing
`sudo nixcage-container` locally; `rebuild` and `down` do not exist there
because `nixos-rebuild` owns the host lifecycle.

**3. macOS: the ADR-002 path, unchanged.** VM config flake, hostname-resolved
`nixosConfigurations`, qemu runner, ssh transport, VM-owned store, VM-local
sops age key, and all five commands.

**4. The CLI gains one seam: transport.** `detect_os` selects local exec
(Linux) or ssh-into-VM (macOS); everything above the seam -- validation, name
derivation, container semantics -- is shared. Adding a platform means adding a
transport, not a second implementation.

## Consequences

- Linux sheds the VM tax: no second store, no VM boot or memory reservation,
  native filesystem speed, and secrets integrate with the sops-nix setup the
  host already has.
- Host-versus-agent isolation on Linux weakens from a VM boundary to a plain
  nspawn boundary (shared kernel, container root is host root behind
  namespaces). This is accepted deliberately and reverses ADR-001's rationale
  for the Linux case; macOS keeps the VM boundary.
- Two lifecycle models exist: on Linux the host module and `nixos-rebuild`
  replace `rebuild`/`down`. Divergence is confined to the transport seam and
  the command surface.
- The Linux host accumulates nixcage state (`/var/lib/nixcage`, nspawn
  sessions) and `enter` requires sudo on the host.
- Config UX differs by platform: a host NixOS module on Linux, a standalone VM
  config flake on macOS. Both are plain NixOS modules sharing option names.
