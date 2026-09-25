---
id: ADR-026
title: A machine is a long-lived microVM that is itself a nixcage host, and the verbs over a cage reach into it by name
status: proposed
date: 2026-09-25
status_date: 2026-09-25
summary: nixcage.machines.<name> boots a NixOS guest running the host module; enter and every cage verb take --machine
depends_on: [ADR-009, ADR-010, ADR-012, ADR-013, ADR-014, ADR-015, ADR-017, ADR-018, ADR-019]
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

The boundary is only as good as what the host does with what the guest
hands it. A guest that is a whole host has root, so everything below
assumes the guest may be hostile and asks what the host parses, mounts or
trusts from it.

## Decision

**1. A machine is declared on the host.** `nixcage.machines.<name>` in the
host module declares a long-lived microVM: `memory`, `cpus`, `diskSize`,
`uidSlice` (a host range, point 5), `placement` (a host bridge and the list
of addresses the machine may speak as), `shares` (host paths bound at the
same path, read-only unless marked writable), and `modules`, NixOS modules
the guest also imports. The name passes the check a cage's name does.

**2. The guest is a nixcage host.** It is built by the host module from the
host's own pkgs, as ADR-019's guest is, and imports `nixosModules.host`. It
boots with systemd as PID 1, runs as root, and sees the host's store as the
read-only share ADR-019 uses. It has no nix daemon: every cage in it runs
`--no-nix-daemon` (ADR-014), with profiles built on the host.
`--substrate microvm` is refused inside a machine, since nothing nests.

**3. The guest's disk is a file, and the host never reads it.** The disk is
a raw image under the host's state directory, on its own dataset where a
pool exists, opened only by qemu; its size is fixed when it is made and is
the bound. It is neither a zvol nor a
loop device, so no block device appears on the host for udev, blkid or
`zpool import` to probe, and no filesystem the guest wrote is parsed by the
host's kernel. The guest formats it ext4 and runs `storage ensure` in
directory mode, so a quota asked inside a machine is refused rather than
ignored; the machine's `diskSize` bounds its cages together.

**4. A machine has a lifecycle verb, and the host alone decides it.**
`nixcage-container machine up|down|status <name>` starts, stops and reports
the host unit `nixcage-machine-<name>.service`, which runs vmspawn. `up`
returns once the guest's `nixcage-container` answers over vsock, bounded by
the timeout `nixcage_microvm_await` already takes. `down` asks the guest to
stop its cages, waits that same bound, then stops the unit whatever the
guest said; the tap, its pins and the share daemons are removed by the host
in the unit's stop, never by the guest. The disk is kept. `up` and `down`
take the machine's lock under the state directory exclusively, and a
forward (point 7) holds it shared from reading the machine ready to the
end of its delivery, so a forward that saw one boot ready is never
delivered to the next boot while it is still coming up.

**5. What crosses a share is mapped, and nothing the guest names is
privileged on the host.** vmspawn's `--bind` translates no ids, so the
machine's shares are served by virtiofsd instances nixcage starts itself
under the machine's unit, each with `--sandbox namespace`, handed to qemu
as `vhost-user-fs` devices through the extra words ADR-019 already passes.
Every share is `--readonly` unless declared writable. A writable share is
served with `--translate-uid map:0:<slice base>:<slice size>` and
`forbid-guest` for every guest uid beyond the slice, and the same for gids,
so guest root is an unprivileged host uid and a setuid-root file cannot be
made. The host mounts nothing the guest wrote; a writable share's host
directory is on a mount with `nosuid,nodev`, which the machine's start
checks and refuses to boot without, since evaluation cannot see a mount. The slices of all machines are disjoint from each other and
from the host's `principalUidRange`, asserted at evaluation, so a file
under a share is attributable to one machine by its owner. Nothing else is
claimed for the slice: the host does not see a guest's processes, only
qemu's.

**6. A cage inside a machine sees its closure, computed by the host.** The
guest has the store without its database, which the host keeps writing,
and a read-only store open of a database under writes is documented by Nix
as unsafe. So `enter --machine` computes the closure on the host with the
query ADR-014 uses, from the roots it parses with the same parse, and
hands the guest the path list; the guest binds exactly those paths.

**7. Every verb over a cage takes `--machine <name>`.** `enter`, `status`,
`stop`, `exec`, `list`, `rm`, `uid` and `storage ensure` with `--machine`
send their argv as argv to the guest's `nixcage-container` over ssh on
vsock as root, with the key vmspawn made, and return its status and output.
The host opens every connection; the guest has no channel to the host
beyond its tap and its shares. `netns` is refused with `--machine`: a
namespace path inside a guest names nothing on the host. The caller's agent
socket is forwarded as `exec` forwards it, which a caller is told gives the
guest the use of that agent while the session runs. Without `--machine`
nothing changes.

`nixcage exec --machine <name> argv`, the fourth primitive of ADR-009,
reaches the machine as `nixcage exec` reaches the host the cages are on:
argv as the guest's root, over the same vsock. It is how a dependant runs
its own program inside the machine, one it installed there through
`modules`, without nixcage knowing what the program does.

**8. What a machine answers is data from outside the boundary.** Output of
a forwarded verb is passed to the caller byte for byte and is never
evaluated or used by nixcage on the host; `list --json` with `--machine` is
validated as JSON before it is printed. A uid a machine's `uid` verb
returns is the guest's number, meaningful inside the guest only. A caller
treats all of it as it would a remote's.

**9. A machine speaks only as its addresses.** Its tap is made as
ADR-019's is, on the host bridge its placement names, pinned to every
address in its list and isolated from the bridge's other ports. Inside, the
guest's `nixcage.bridges.<b>` gains `uplink`, which enslaves the guest's
NIC, so a cage placed on it with `--network <b>:<addr>` reaches the host
bridge with its own address. The guest pins each cage's veth to its address
(ADR-015); the host's pin bounds the machine to its list whatever the guest
does. A cage's address is what a peer on the host bridge sees.

## Consequences

The exported interface (ADR-009) grows by one flag, on `nixcage exec` and
on the verbs over a cage, and one verb. A dependant that never says
`--machine` sees nothing new. nixcage still
knows nothing of what a machine is for.

The host's attack surface toward a machine is KVM and qemu's devices, the
virtiofsd instances (sandboxed, read-only unless declared, ids mapped), the
tap under the bridge-family table, and the ssh client reading the guest's
output. The raw disk and the ext4 in it are qemu's to read and the guest's
to parse.

A machine reserves its memory and pays a boot at `up`, not per session;
cages inside start at nspawn speed. A panic or an OOM in a machine ends
every cage in it and nothing outside it.

Inside a machine a cage has no quota of its own and ZFS's datasets are not
there. A dependant that needs one cage bounded apart from its peers puts
it in a machine of its own.

Every verb gains a vsock hop, and `enter` a closure query on the host.
Their cost is measured, not claimed.

A machine's lifecycle interleaves with `enter --machine`, `down`, a host
stop of the unit, and a guest that crashes, hangs or lies, across the vsock
boundary: the Formal Modeling Gate. `models/machine.qnt` models the
host's view (off, booting, ready, stopping, failed), a guest that may stop
answering or die at any step, a stop of the unit from outside, and two
callers forwarding concurrently. Run 2026-09-25 with
`quint run models/machine.qnt --invariant=all_invariants --max-steps=60
--max-samples=100000`: no violation in 100000 traces of 60 steps, and each
witness (ready, a cage running, stopping, failed) reached. Its first run
found that a forward holding a check across a crash was delivered to the
next boot while it booted, which is why `up` takes the lock as `down` does;
with `up` not waiting, `noCheckAcrossBoot` is violated within 100000 traces,
and each guard turned off violates its invariant: without the lock,
`noDeliveryUnlessReady`; with cleanup left to the guest, `offMeansClean`.

macOS is not a host for machines: its cages already share one VM, and it
cannot nest another.

## Measurement plan

`legacyPackages.hostChecks.machine`, a NixOS test run with
`nix build -L .#hostChecks.machine` on a host with nested KVM, and the same
steps by hand on `pc`, transcripts under `/tmp/nixcage-machine/`:

- Boot to ready: `time nixcage-container machine up m1`.
- Idle cost: `systemctl show -p MemoryCurrent nixcage-machine-m1.service`
  after `up`, and again with one idle cage inside.
- Forward cost: `time nixcage-container enter --machine m1 c1 /srv/p true`
  against the same enter without `--machine`, ten runs each.
- The kernel: `nixcage-container exec --machine m1 c1 uname -r` differs
  from the host's `uname -r`.
- The closure: inside a cage in `m1`, `ls /nix/store | wc -l` equals the
  length of the host's `nix-store --query --requisites` over its roots.
- The shares: as guest root, `touch` on a read-only share fails; on a
  writable one the host's `stat -c %u` is the slice's base; `chown 0` and
  `chmod u+s` on it leave the host file neither root-owned nor setuid.
- The disk: `lsblk` and `zpool import` on the host list nothing new after
  `up`.
- The pin: from guest root in `m1`, a frame sourced from an address not in
  `m1`'s list is dropped at the host tap; `nft list set bridge nixcage
  placements` names each listed address and no other.
- Two machines: a cage in `m1` does not reach a cage in `m2` on the same
  host bridge.
- A hostile `down`: with the guest's sshd stopped from inside, `machine
  down m1` returns within the bound and leaves no `nc-*` link, no placement
  element and no virtiofsd of `m1`.

## Verification

Implemented 2026-09-25 in four commits from `134b0ee` to the one that
records this, after the model (`985ddbb`). `nix build -L
.#hostChecks.machine`, a NixOS test booting two machines under nested KVM,
passes seventeen subtests, one per claim of the measurement plan but the
cost, which the plan measures on `pc`:

- a machine comes up ready and is a kernel of its own; a cage entered with
  `--machine` runs on the machine's kernel, not the host's (told apart by
  uptime, since nspawn gives a container a boot id of its own), and its
  record is the machine's, not the host's;
- the cage sees exactly the closure the host computed: `ls /nix/store`
  inside counts what `nix-store -qR` over `STORE_BASE` counts;
- a host cage cannot take a machine's name; `netns --machine` is refused;
- a read-only share refuses writes; what guest root writes on a writable
  one is `900000:900000` here, and stays so after `chown 0` and
  `chmod u+s`; `chown 70000` is refused;
- the caller's agent answers inside and keeps its owner;
- a cage reaches a host service on the bridge as its own address; an
  address the machine was not given is dropped at the host's tap; a cage
  in one machine gets no answer from a cage in another, which its own
  machine reaches;
- `list --json` from a machine is valid JSON lines, and empty when it
  holds no cage;
- state survives `down` and `up` on `/var/lib/nixcage`, which is ext4 on
  `/dev/vda`; the host lists no loop device;
- with the guest's sshd stopped from inside, the machine reads `booting`,
  and `down` returns in 0.37 s leaving no tap, no placement element and no
  virtiofsd.

Nested, and so only an indication of the plan's numbers: `machine up`
15 to 19 s, `enter --machine` for one command 2.1 s, a cooperative `down`
3.7 to 4.0 s.

Not yet done: the measurement plan by hand on `pc`, which needs a machine
declared in the host's configuration.

