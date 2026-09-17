---
id: ADR-019
title: A cage may run in a microVM under systemd-vmspawn, chosen when the cage is defined, behind the same enter
status: proposed
date: 2026-09-17
status_date: 2026-09-17
summary: enter --substrate microvm boots a NixOS guest with vmspawn from the same parse; own kernel, no daemon, same verbs
depends_on: [ADR-003, ADR-009, ADR-010, ADR-011, ADR-012, ADR-014, ADR-017]
supersedes: []
superseded_by: []
---

## Context

ADR-003 accepted that on Linux the boundary between the host and what runs in
a cage is the container boundary alone: one kernel, shared. ADR-001 had a
kernel per project and was superseded for its cost, not for its boundary.
Two asks bring the boundary back, per cage rather than for all of them: a
tool trusted less than the others should not share the host's kernel; and a
tool that needs its own kernel (docker inside a cage, eBPF, mount and cgroup
namespaces of its own, kernel modules) cannot run in a container at all.

The interface must not change. A dependant holds `enter` and its flags
(ADR-009); a second way to isolate a cage that needed a second verb would be
a second product. What already makes this possible: `modules/enter-args.sh`
parses `enter` with no knowledge of nspawn; `modules/bind.sh` produces bind
words that are nspawn's and, as it turns out, vmspawn's; the verbs over a
running cage read a systemd scope (ADR-012), not nspawn; the record
(ADR-017) is substrate-blind.

`systemd-vmspawn` is nspawn's sibling for virtual machines. Checked in the
pinned nixpkgs (`d6c71932`, systemd 258.3, `withVmspawn ? true`) and the
v258 manual: `--directory` (root over virtiofs), `--linux`/`--initrd`
(direct kernel boot), `--bind`/`--bind-ro` with nspawn's exact syntax,
`--private-users=SHIFT[:RANGE]` (virtiofsd uid mapping), `--network-tap`,
`--cpus`, `--ram`, `--slice`, `--property`, `--register` (machined),
`--vsock`, `--set-credential`, `--console`, `--machine`. Missing against
nspawn: no command argv (it boots an init), no `--setenv`, binds are
directories only. Those three gaps are what this document fills.

## Decision

**1. A second substrate behind the same parse.** `enter --substrate
nspawn|microvm`. The word "substrate" names what sits under a session and
makes it a cage. The nspawn path is unchanged byte for byte. The microvm
path is a second argv assembler, `modules/vmspawn-args.sh`, from the parse
`enter-args.sh` already produces; `--print-argv` shows either.

**2. The choice is made when the cage is defined, and then it is fixed.** In
precedence: a declaration on the host module,
`nixcage.cages."<project path>".substrate`; else the record of the first
`enter` (ADR-017 gains a `substrate` field); else the flag; else
`nixcage.substrate.default`. A flag that conflicts with a declaration or a
record is refused before anything boots, naming the winner and its source.
`rm` clears the record. `modules/substrate.sh` holds the resolution;
`list --json` shows the field. On macOS `--substrate microvm` is refused:
the shared VM cannot nest another without hardware and kernel support that
this document does not assume.

**3. One guest system per host, not per cage.** `modules/guest.nix` is a
NixOS configuration the host module builds at rebuild: kernel, initrd, a
root store path handed to `--directory`. It carries one unit,
`nixcage-session.service`, which reads the credential `nixcage.session`
(JSON: uid, gid, home, cwd, env, argv, tty, address), configures its
interface when given an address, binds `SSH_AUTH_SOCK` at
`/run/ssh-agent.sock` when forwarded, runs argv as that uid on `/dev/hvc0`
when tty else captured, writes argv's exit status to `.nixcage-exit` in the
home share, `fsync`s it, and powers off. The host reads the file after the
scope is gone; the probe checks the write reached the host under the share's
cache mode. This is how a VM without argv gets one.

**4. A microVM cage never has a daemon.** ADR-014's contract, always: the
session sees store paths and cannot build. Nothing from inside installs or
builds via nix. The daemon socket cannot cross a VM, and proxying it over
vsock would put the daemon protocol inside the boundary this document
exists to draw. `--no-nix-daemon` is implied; `--shell` is refused as
ADR-011 refuses it without the daemon.

**5. What crosses.** Read-only over virtiofs: `/nix/store` whole, and every
`--bind-ro`. Read-write over virtiofs, uid-shifted by `--private-users`
from the cage's block (ADR-010): the project at its path, the home at
`/root`, every `--bind`. Once, as bytes in guest memory: the credential,
with `secretEnv` values resolved on the host. As channels: the console, and
vsock ssh for `exec` and `ssh -A`; a socket reaches the guest, a key never
does (ADR-008). Never: the daemon socket, the host's network namespace,
`/proc`, `/sys`, devices, other cages. Guest root is read-only; `/etc`,
`/var`, `/tmp` are tmpfs and die with the session, except that `--disk
<size>` (new flag) gives the cage a persistent image, handed in with
`--extra-drive` and mounted at `/var/lib`, for docker's images and anything
virtiofs is too slow for. The image sits in a directory `storage ensure`
gave the cage's uid under `/var/lib/nixcage` with `<size>` as its quota
(ADR-009), so it is owned and bounded like every other thing a cage keeps.

**6. Verbs.** `status` and `stop` are unchanged: vmspawn registers a scope
under `machine.slice` and `modules/scope.sh` reads it. `--memory` becomes
`--ram` and `--cpus` stays `--cpus`: the bound is the guest's, so the
guest kernel kills the process that exceeds it and the session survives,
which is ADR-012's promise. A `MemoryMax=` on the scope would bound qemu
itself and kill the whole VM instead. `netns` answers `none`, exit 0: a VM
has no namespace on the host. `exec` runs `machinectl shell <name>` over
vmspawn's vsock ssh; user and `--setenv` values come from the record, and
`secretEnv` values are resolved from `/run/secrets` at exec time by the
same path enter uses, since the record holds names and there is no leader
on the host whose environment could be read. A
placement (`--network`) attaches vmspawn's tap to the bridge with ADR-015's
pin and isolation, in `modules/veth.sh` beside the veth case: a second port
kind on a bridge, extended, not extracted.

**7. Refusals before boot.** No `/dev/kvm`; `systemd-vmspawn --version`
below 258 or absent; a conflicting substrate; a missing bridge; a
credential over the size vmspawn's credential path carries (measured in
the plan, then a constant here); the second `enter` on a running name.
After boot: no `READY=1` from the session unit within `--boot-timeout`
(30 s) is `stop`, exit 124, last console lines on stderr; a missing
`.nixcage-exit` after poweroff is exit 255, "session ended without status";
a scope alive 5 s after the status was read is stopped.

## Consequences

The kernel boundary is bought per cage at the price of a boot (about one to
three seconds against nspawn's tenth), memory reserved rather than shared,
and one virtiofsd per share. A caller pays it only for the cages it names.

The store is shared whole and read-only, wider than ADR-014's closure view.
ADR-014 narrowed the view because a daemon-less nspawn cage could still read
what other cages' closures left in the store; this document's boundary is
the kernel, and the store holds no secrets by policy. Accepted as a widening
and stated here so it is revisited if a store secret ever matters.

A dependant sees one new flag and one new answer (`netns` says `none`). The
four primitives keep their vocabulary. Nothing here knows what runs inside.

`systemd-vmspawn` is young and NixOS has no module for it. Each flag above
exists in 258; four things the design rests on are unverified and are a
spike on the Linux host before any code or model: a NixOS guest booting
with its root over virtiofs from `--directory` by `--linux`/`--initrd`
(stage 1 must mount the `root` tag); `machinectl shell` reaching a VM
(sshd on AF_VSOCK in the guest via `systemd-ssh-generator`, the key vmspawn
generates); the scope name machined gives a VM (`scope.sh` assumes
`machine-<name>.scope` under `machine.slice`); and whether
`--private-users` shifts `--bind` shares as well as the root, without
which project files are owned by an unshifted uid and ADR-004 does not
hold on this substrate. If vmspawn fails any of them, the fallback is
writing the qemu line by hand, and the parse, the credential, the guest
unit and the verbs stay.

ADR-003's statement that host-versus-tool isolation on Linux rests on the
container boundary alone becomes true of the nspawn substrate only. ADR-003
gets an amendment line saying so when this document is accepted; it is not
superseded, since every nspawn cage still lives by it.

The session lifecycle (boot, ready, running, exited, status written, powered
off, stopped by the host, with timeouts and a host that may die) crosses a
VM boundary with more than three states. The formal modeling gate applies:
a Quint model of it, with the invariants "the host never reports success
without a status", "no VM outlives its record unseen by `list`" and "stop
converges", is written before the guest unit and the host-side protocol are
coded. Substrate resolution is a pure function of four inputs and gets a
table, not a model.

## Measurement plan

On a Linux host with the host module, `/dev/kvm`, a declared bridge and
docker in a project's devShell:

```bash
time nixcage enter --substrate microvm /path/to/project true      # boot cost
nixcage enter --substrate microvm /path/to/project false; echo $?  # 1
nixcage enter --substrate microvm --memory 256M /path/to/project -- \
  python3 -c 'x = bytearray(512 * 2**20)'; echo $?                # killed
nixcage enter --substrate microvm --disk 2G /path/to/project -- \
  sh -c 'dockerd & sleep 3; docker run --rm hello-world'          # own kernel
nixcage enter --substrate microvm --network br0:10.0.0.2/24 /path/to/project -- \
  sh -c 'curl -s http://10.0.0.1/ && ! curl -s --max-time 2 http://1.1.1.1/'
nixcage enter --substrate nspawn /path/to/project true            # refused, names the record
nixcage netns <name>                                              # none
nixcage enter --substrate microvm /path/to/project -- \
  sh -c 'touch /workspace-owned; stat -c %u /workspace-owned'      # owner uid on host
nixcage enter --substrate microvm --setenv BIG=$(head -c 200000 /dev/zero | tr '\0' x) \
  /path/to/project true                                           # credential bound
```

Spike, before the plan and before any code: a hand-written `systemd-vmspawn
--directory=<nixos root> --linux=<kernel> --initrd=<initrd>
--bind=/tmp/probe --private-users=<shift>:65536 --register=yes` on the
host, then `machinectl shell <name>`, `systemctl status
machine-<name>.scope`, and `stat` of a file the guest writes under
`/tmp/probe`. Four answers, recorded here.

The claim: a `true` session boots and exits under three seconds with KVM;
the hog is killed and the session returns; a file the guest writes in the
project is owned by the project owner on the host; the credential line
either passes or is refused before boot naming the bound; every other line
behaves as written. Times and outputs are recorded in this
document's Verification section when run.

## Verification

Proposed 2026-09-17. `tests/unit/substrate.bats` (resolution table and
refusals), `tests/unit/vmspawn_args.bats` (parse to words, binds equal to
nspawn's, credential shape and size, `--disk`), `tests/command/modules.bats`
(guest evaluates, session unit present, systemd assertion), `veth.bats` (tap
on a bridge), `scope.bats` and `exec_cage.bats` (microvm record: `netns`
none, `exec` words), an exit-status fixture suite, the guest built on a
Linux builder, and the measurement plan on a machine.
