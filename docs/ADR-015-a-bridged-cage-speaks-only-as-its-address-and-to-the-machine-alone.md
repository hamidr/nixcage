---
id: ADR-015
title: A bridged cage speaks only as its address, and reaches the machine and never a peer
status: implemented
date: 2026-09-16
status_date: 2026-09-16
summary: nixcage pins a placement address on its port and isolates the port; the two bridge rules a dependant wrote are its own
depends_on: [ADR-011, ADR-013]
supersedes: []
superseded_by: []
---

## Context

ADR-011 gave a cage one veth on a named bridge at a named address, and its
Consequences handed the rest to the caller: "what may cross it is the host's
ruleset and not nixcage's: the rules cageworks needs are keyed on the veth
name nspawn chooses and the address the caller passed, so both are the
caller's to know." ADR-013 then took the veth's name from nspawn, hashed it
from the cage's name, and told the caller the hash two ways, `lib.vethHostName`
and the `veth <name>` verb, so the caller could still key its rules on it.

The dependant's rules are two. A frame on a cage's port whose source is not
the address that port was given is dropped, IPv6 and ARP included, because
the dependant bills by address and a cage that claims a peer's address bills
the peer. A frame from one cage's port to another cage's port is dropped,
because the two have nothing to say to each other that does not go through
the machine. Neither rule mentions anything of the dependant's: both are
statements about a placement, and a placement is what ADR-011 exports.

Keeping them in the dependant has a cost on both sides. The dependant's
firewall is written in nixcage's dialect: `iifname "nc-*"`, a set filled by
asking `veth` for each name. A change to the hash is a firewall that matches
nothing, silently, on a machine whose cages can then bill each other. The
export and the verb exist only to make that coupling possible, which is the
sourceable-library shape ADR-009 rejected. And any second dependant that
puts two cages on one bridge wants the same two rules and would write them
again.

Two facts of the host decide where the rules live. NixOS's
`networking.nftables.tables` declares a table by enabling nftables, which
moves the host's whole firewall to that backend and conflicts with anything
on the host still using iptables; a host module that did that to a Linux
host for the sake of a bridge would be deciding something it was not asked.
And a declared table is deleted and recreated when the ruleset reloads,
which wipes any element added since boot: a running cage's pin, gone
without a word. The dependant's ruleset has both properties today.

The cage retains `CAP_NET_ADMIN` (ADR-011 point 2), so cage root can set a
second address. A rule on the host side of the port makes that harmless; a
rule inside the cage would not.

## Decision

**1. nixcage makes its own table at runtime and declares none.** Before the
first pair is made, `nixcage_veth_make` adds, idempotently, a bridge-family
table `nixcage`, a set `placements { type ifname . ipv4_addr }`, a
prerouting chain and a forward chain, and refills the two chains' rules by
flushing each chain and adding them, which leaves the set alone. The
prerouting chain drops, on any port named `nc-*`, an IPv6 frame, an ARP
frame whose sender address is not the port's element, and an IP frame
whose source is not the port's element. The forward chain drops a frame
from one `nc-*` port to another. No NixOS module option is touched: the
kernel takes an nftables table beside an iptables firewall, and a reload of
the host's declared ruleset does not know the table exists.

**2. A placement is pinned when the pair is made and released when it is
deleted.** `nixcage_veth_make` takes the address beside the bridge, deletes
any element under the host end's name and adds `{ <host end> . <address> }`
after the host end joins the bridge; `nixcage_veth_delete` deletes the
element before the pair goes. A stale pair from a killed session loses its
element with the pair, as it loses the pair today.

**3. The port is isolated.** `nixcage_veth_make` sets `bridge link set dev
<host end> isolated on`, so the kernel drops port-to-port frames before any
chain runs; the bridge's own address is not a port, so a cage still reaches
the machine. The forward rule of point 1 stays as the statement the ruleset
can be read for; the flag is what makes it never fire.

**4. `lib.vethHostName` and the `veth <name>` verb are withdrawn.** No
dependant needs the name once the rules that used it are here. ADR-013
keeps the hash and the reason for it; what changes is that nobody outside
is told.

**5. The promise, in SPEC.md.** A cage placed with `--network
<bridge>:<address>/<prefix>` sends as that address and no other, and reaches
the bridge's own address and no other port. A caller that wants a cage to
reach a peer runs a service on the bridge that both reach.

## Consequences

`modules/veth.sh` grows the nft and bridge words beside the ip words; the
suite drives it with `nft` and `bridge` stubbed as it drives `ip`.
`nftables` enters the guest script's closure by store path as `iproute2`
did. `flake.nix` loses one export and the usage line loses one verb, which
is a breaking change for the one dependant, taken with its lock bump.

The dependant's bridge-family table, the set it filled from the plan, and
the `nft add element` at prepare are removed there, not kept as a second
copy: two rulesets saying the same thing drift, and the one that drifted
wrong is invisible while the other holds.

`CAP_NET_ADMIN` stays retained inside the cage. Dropping it would need the
address set from outside after the leader exists, which is a race the pin
makes unnecessary: a second address a cage gives itself sends nothing.

A table made at runtime is not in the host's declared ruleset, so `nft
list ruleset` on the host shows a table the host's configuration does not
mention. That is the cost of not deciding the host's firewall backend, and
SPEC.md names the table so an operator reading the ruleset knows whose it
is.

## Verification

No model: the two rules are stateless filters on one frame, and the one
temporal property worth checking, that a pin survives a ruleset reload, is
settled by point 1 making the table one the reload does not touch. A bats
scenario with `nft` stubbed says everything a model would.

`tests/unit/veth.bats`: the first make creates the table, set and chains
and refills the chains; a make adds the element after the master is set and
isolates the port; a make under a name with a stale element deletes it
before adding; delete removes the element before the link.
`tests/unit/exports.bats`: `lib` has no `vethHostName`.
`tests/command/cli_dispatch.bats`: `veth` is not a verb. The guest script
builds, which runs shellcheck over the new words.

What needs a machine is the dependant's proof, as ADR-011 and ADR-013 have
it: `tests/manual/isolation.sh` in the dependant, two cages on one bridge;
from the first, a frame as the second's address is not seen on the bridge,
a packet to the second's address gets no reply, and a packet to the
bridge's address does. Recorded here when run.

Implemented 2026-09-16: `modules/veth.sh` makes the table, pins and
isolates the port and releases the pin, driven by `tests/unit/veth.bats`
with `ip`, `nft` and `bridge` stubbed; `modules/container.nix` passes the
placement's address to the make, releases the pin from the session's trap,
carries `nftables` and dispatches no `veth`; `flake.nix` exports no
`vethHostName`, which `tests/unit/exports.bats` asserts. The guest script
builds on a Linux builder. Open: the dependant's measurement above.

Measured 2026-09-16 on a fabriek machine (fabriek `1af4e65`, this
repository at `3cdcfe6`): `tests/manual/isolation.sh` against a factory of
six roles on `fabriek0`, all six of the bridge's Thens passing. A cage
sees `host0` and nothing else besides `lo`; two roles hold two addresses
(`10.77.0.10`, `10.77.0.11`); a connection from one cage to the other's
address fails and one to the proxy on the bridge's address answers; a
request from the first cage's namespace forged as the second's address
moves no count at the proxy, while an honest request moves the sender's
and nobody else's. The dependant records the same run beside its bridge
decision.
