---
id: ADR-018
title: The host module owns a bridge a cage may be placed on
status: implementing
date: 2026-09-16
status_date: 2026-09-16
summary: nixcage.bridges.<name> declares a bridge with its address and the two settings an empty bridge needs to be usable
depends_on: [ADR-003, ADR-011, ADR-015]
supersedes: []
superseded_by: []
---

## Context

ADR-011 says the bridge has to exist before the session starts and leaves
making it to the caller. The dependant made one with NixOS's
`networking.bridges` and found, on a machine, two things a bridge whose only
ports come and go needs and NixOS does not give: networkd withholds an
address from a link without carrier, and an empty bridge has none, so every
service that listens on the bridge's address failed to bind until the first
cage arrived; and a service that binds before the address is up needs
`net.ipv4.ip_nonlocal_bind`. Both were found by services failing on a
booted machine and fixed there.

They are not the dependant's facts. Any bridge whose ports are cages has
them, because a cage is a port that is there only while a session runs.
The place they belong is beside the module that adds the ports.

## Decision

**1. `nixcage.bridges.<name> = { address; prefix; }` on the host module.**
For each, the module declares the bridge with no static ports, the address
on it, `ConfigureWithoutCarrier` on its networkd unit, and the sysctl. On
the VM module the same option renders into the guest.

**2. The bridge's name is checked where declared,** to the kernel's fifteen
characters and an interface's alphabet, the same check `enter --network`
applies to the name it is given.

**3. Nothing else.** Which ports a bridge's cages may reach on the bridge's
address is the host's firewall and the caller's to open; nixcage declares no
`allowedTCPPorts`. What crosses between ports is ADR-015's.

## Consequences

`modules/host.nix` and `modules/nixcage.nix` gain one option and the four
settings it renders. A caller that already declares its bridge with
`networking.bridges` keeps working; the option is for one that would rather
not learn the two settings the hard way; one that adopts the option deletes
its own declaration in the same change, since two declarations of one
bridge do not merge.

## Verification

Both modules evaluate with one bridge declared and with none; the rendered
configuration carries the address, `ConfigureWithoutCarrier = true` on the
bridge's network unit, and the sysctl; a name of sixteen characters is
refused at evaluation. On a machine: the bridge's address is present with
no cage running, and a service bound to it answers before the first cage
enters.

Implemented 2026-09-16: `modules/bridges.nix` holds the option and the
four settings, imported by `modules/host.nix` and `modules/nixcage.nix`;
`tests/command/modules.bats` evaluates both as NixOS systems with one
bridge and with none, reads the address, the carrier setting and the
sysctl back, and sees a sixteen-character name and one outside the
alphabet refused. Open: the machine half above, which the dependant's
machine will show when it adopts the option.
