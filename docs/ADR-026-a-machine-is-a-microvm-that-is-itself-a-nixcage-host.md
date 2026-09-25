---
id: ADR-026
title: A machine is a long-lived microVM that is itself a nixcage host, and the verbs over a cage reach into it by name
status: proposed
date: 2026-09-25
status_date: 2026-09-25
summary: nixcage.machines.<name> boots a NixOS guest running the host module; enter and every cage verb take --machine
depends_on: [ADR-009, ADR-010, ADR-012, ADR-013, ADR-015, ADR-017, ADR-018, ADR-019]
supersedes: []
superseded_by: []
---

## Context

ADR-019 gives one cage a kernel of its own: a microVM session that runs one
argv as the owner's uid and powers off. A cage that is a microVM holds one
subject, cannot host other cages, and pays a boot per session. ADR-003 gives
many cages one kernel: the host's.

A dependant has asked for the shape between the two. fabriek wants a kernel
boundary around a group of cages, not around each one: the cages of a group
cooperate and may share a kernel, and an escape from any of them must land
in the group's kernel, not on the host or in another group. Today it can
only choose per cage, so a group of seven cages is either seven guests or
none.

The parts exist. The guest ADR-019 builds from the host's pkgs, the
read-only store share, the tap a placement is handed (ADR-013, ADR-015), and
ssh over vsock as the guest's root are all in the tree. What is missing is a
guest that is a nixcage host instead of a one-shot session, and a way to
name it from the host.

## Decision

**1. A machine is declared on the host.** `nixcage.machines.<name>` in the
host module declares a long-lived microVM: `memory`, `cpus`, `disk` (a zvol
under `storage.dataset` where a pool exists, else a raw image under the
state directory), `principalUidRange`, `placement` (a host bridge and the
list of addresses the machine may speak as), `shares` (host paths bound at
the same path, read-only unless marked), and `modules`, NixOS modules the
guest also imports. The name passes the check a cage's name does.

**2. The guest is a nixcage host.** It is built by the host module from the
host's own pkgs, as ADR-019's guest is, and imports `nixosModules.host`. It
boots with systemd as PID 1, runs as root, keeps its state on its disk, and
sees the host's store as the read-only share ADR-019 uses. It has no nix
daemon: every cage in it runs `--no-nix-daemon` (ADR-014), with profiles
built on the host. `--substrate microvm` is refused inside a machine, since
nothing nests.

**3. A machine has a lifecycle verb.** `nixcage-container machine
up|down|status <name>` starts, stops and reports the host unit
`nixcage-machine-<name>.service`, which runs vmspawn. `up` returns once the
guest's `nixcage-container` answers over vsock, bounded by the timeout
`nixcage_microvm_await` already takes. `down` stops every cage in the
machine and then the guest; its disk and uid slice are kept.

**4. Every verb over a cage takes `--machine <name>`.** `enter`, `status`,
`stop`, `exec`, `list`, `rm`, `uid` and `storage ensure` with `--machine`
send their argv as argv to the guest's `nixcage-container` over ssh on
vsock as root, with the key vmspawn made, and return its status and output
unchanged. `netns` is refused with `--machine`: a namespace path inside a
guest names nothing on the host. The caller's agent socket is forwarded as
`exec` forwards it. Without `--machine` nothing changes.

**5. A machine's uids are a slice of the host's.** Each machine's
`principalUidRange` is disjoint from the host's and from every other
machine's, asserted at evaluation. A number the guest allocates is
therefore a number no other machine or host cage holds, so a file a share
carries back and a process the host sees are attributable without a map.

**6. A machine speaks only as its addresses.** Its tap is made as ADR-019's
is, on the host bridge its placement names, pinned to every address in
its list and isolated from the bridge's other ports. Inside, the guest's
`nixcage.bridges.<b>` gains `uplink`, which enslaves the guest's NIC, so a
cage placed on it with `--network <b>:<addr>` reaches the host bridge with
its own address. The guest pins each cage's veth to its address (ADR-015);
the host's pin bounds the machine to its list. A cage's address is what a
peer on the host bridge sees, unchanged by the hop.

## Consequences

The exported interface (ADR-009) grows by one flag and one verb. A
dependant that never says `--machine` sees nothing new. nixcage still
knows nothing of what a machine is for.

A machine reserves its memory and pays a boot at `up`, not per session;
cages inside it start at nspawn speed. A panic or an OOM in a machine
ends every cage in it and nothing outside it.

The guest's disk is a block device, not a share: nothing the cages write is
parsed by the host's filesystem code, which is the boundary. A dependant
that must read a cage's output on the host reads it over the network or
through a declared share, and says which.

Every verb gains a transport hop over vsock. Its cost is measured, not
claimed.

A machine's lifecycle interleaves with `enter --machine`, `down`, a host
stop of the unit and a guest crash, across the vsock boundary, which is the
Formal Modeling Gate. `models/machine.qnt` models absent, booting, ready,
stopping and failed, with invariants: no forward reaches a machine that is
not ready, `down` leaves no cage running and no pin behind, and `up` twice
is `up` once. It runs before implementation.

macOS is not a host for machines: its cages already share one VM, and it
cannot nest another.

## Measurement plan

`legacyPackages.hostChecks.machine`, a NixOS test run with
`nix build -L .#hostChecks.machine` on a host with nested KVM, and the same
steps by hand on `pc`, transcripts under `/tmp/nixcage-machine/`:

- Boot to ready: `time nixcage-container machine up m1`.
- Idle cost: `systemctl show -p MemoryCurrent nixcage-machine-m1.service`
  after `up`, and again with one idle cage inside.
- Forward cost: `time nixcage-container enter --machine m1 c1 /srv/p -- true`
  against the same enter without `--machine`, ten runs each.
- The kernel: `nixcage-container exec --machine m1 c1 -- uname -r` differs
  from the host's `uname -r`.
- The uids: `stat -c %u` on a file a cage wrote to a share falls inside
  `m1`'s slice and outside every other range.
- The pin: from inside `m1`, a frame sourced from an address not in `m1`'s
  list is dropped at the host tap (`nft list set bridge nixcage
  placements` names each listed address and no other).
- Two machines: a cage in `m1` does not reach a cage in `m2` on the same
  host bridge.
- `down`: after `nixcage-container machine down m1`, no `nc-*` link and no
  placement element of `m1` remain.
