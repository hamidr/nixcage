---
id: ADR-013
title: nixcage makes a cage's veth and names it, so a cage name is not bounded by an interface name
status: proposed
date: 2026-09-14
status_date: 2026-09-14
summary: for a bridge placement nixcage makes the veth pair, names the host end from a hash, and tells the caller that name
depends_on: [ADR-011, ADR-012]
supersedes: []
superseded_by: []
---

## Context

ADR-011 point 1 places a cage on a bridge with nspawn's `--network-bridge`,
which makes the veth pair and names the host end after the machine: `vb-`
plus the cage's name. Linux bounds an interface name at fifteen characters,
so a cage's name is bounded at twelve, and the dependant carries that bound
in its own name check and its scenarios, one interface deep from where it
comes from. ADR-011 also left the veth name "nspawn's to choose", so the
host's rules key on a name nixcage never wrote down.

nspawn takes an existing interface with `--network-interface=HOST:CAGE`,
renames it `CAGE` inside, and on termination moves it back under its host
name. A veth pair nixcage makes before the session, with the host end on
the bridge and the cage end handed to nspawn under that option, is the
same cage on the same bridge with a host end named by nixcage.

## Decision

**1. For a bridge placement, nixcage makes the pair.** Before the session:
`ip link add <host> type veth peer name <cage>`, the host end set master
to the named bridge and up; nspawn gets `--network-interface=<cage>:host0`
and no `--network-bridge`. The cage still sees `host0` and sets its
address on it as ADR-011 has it. The pair is deleted when the session
ends, whichever way it ends.

**2. The host end is named from the cage's name, not with it.** `nc-`
plus the first twelve hex digits of `sha256(<name>)`: fifteen characters
for any name, no collision in practice, the same name every time for the
same cage. The cage end is the same with a `c` in place of `n` and lives
only until nspawn renames it.

**3. The caller is told the name.** `nixcage-container veth <name>` prints
the host end's name, a pure function of the cage's name that needs no
running cage. A host's rules key on what nixcage printed, never on a
prefix they assume.

**4. The bound on a cage's name is nspawn's, not an interface's.** A cage
name is a machine name: the alphabet `check_name` allows, at most
sixty-four characters. A dependant that bounded names at twelve for the
veth's sake deletes that bound.

**5. `ns:` placements are untouched.** A session joining a running cage's
namespace makes no interface, as before.

## Consequences

`modules/veth.sh` holds the names, the `ip` words to make and delete a
pair, and the nspawn argument, driven by the suite with `ip` stubbed;
the guest script's network block calls them and its EXIT trap deletes the
pair. `iproute2` was already in the guest script's closure.

A pair made and not handed over, because nspawn failed to start, is
deleted by the trap like a rootfs is. A pair whose cage end nspawn moved
back is a pair with both ends on the host until the trap runs, which is
the session's own exit.

The host end's name carries no hint of the cage; `veth <name>` is how a
person reading `ip link` finds out. That is the price
of a name that fits, and the two verbs are the receipt.

## Verification

```bash
nix develop --command bats tests/unit/veth.bats tests/unit/enter_args.bats
nix develop --command shellcheck nixcage modules/*.sh
nix build .#nixcage
```

`tests/unit/veth.bats` drives `modules/veth.sh`: the host name for a
short and a long cage name, both fifteen characters or fewer and stable;
the `ip` words to make a pair on a bridge and to delete it; the nspawn
argument. What needs a machine is a cage placed on a bridge reaching the
bridge's address and nothing else, as ADR-011 measured, with a
twenty-character name; recorded here when run.
