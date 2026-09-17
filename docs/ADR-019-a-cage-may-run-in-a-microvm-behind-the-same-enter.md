---
id: ADR-019
title: A cage may run in a microVM under systemd-vmspawn, chosen when the cage is defined, behind the same enter
status: implementing
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
v258 manual, and then against 261, which is the first that boots a kernel
directly without UEFI firmware (`--firmware=none`; 258 wants an OVMF it
does not find on NixOS), so 261 is the floor: `--directory` (root over virtiofs), `--linux`/`--initrd`
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
NixOS configuration the host module builds at rebuild, from the host's own
`pkgs` so the guest's systemd is the host's vmspawn's: kernel, initrd, and
the toplevel. `--directory` gets an empty skeleton per session, owned by
the cage's first uid, since virtiofsd runs in a user namespace and cannot
create in a directory it does not own; the store is a `--bind-ro`, which
the initrd mounts under `/sysroot` before it looks for the closure.
vmspawn writes its own `-append` and has no flag to extend it, so
`init=<toplevel>/init` reaches the kernel through
`SYSTEMD_VMSPAWN_QEMU_EXTRA="-append '...'"` repeating vmspawn's three
words, because qemu keeps the last `-append`; `--print-argv` shows the
line and the probe checks it. Credentials arrive as SMBIOS type 11
strings, which the NixOS kernel exposes only once `dmi_sysfs` is loaded,
so the initrd loads it. The guest carries one unit,
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
`--bind-ro`. Read-write over virtiofs, as the host uid: the project at its
path, the home at `/home/<subject>` (`/home/nixcage` for a session with
none: a microVM session is never guest root, and the guest owns `/root`
as root's, re-owning a home bound there), every `--bind`. `--private-users` shifts only the root
share, and virtiofsd for every other share runs as host root and hands
uids through unchanged, so the session runs argv as the project owner's
host uid inside the guest (ADR-004 by identity, not by ADR-010's block),
and the block is what the skeleton's owner is drawn from. A process that
becomes root in the guest writes the shares as host root, which ADR-010
prevents on nspawn; stated here as the substrate's edge, to be closed by
an idmapped mount of the shares in the guest when its kernel allows it.
Once, as bytes in guest memory: the credential, with `secretEnv` values
resolved on the host. As channels: the console, and
vsock ssh for `exec` and for the agent, which arrives as a remote unix
socket forward (`ssh -N -R /run/ssh-agent.sock:<host socket>`) held for
the session's life, so what appears in the guest is a socket sshd made;
`-A` would give it to root's login only, under a path only root reaches.
A socket reaches the guest, a key never does (ADR-008). The guest's
session unit waits up to 15 s for the socket before argv runs, since the
forward can only hold once the guest's sshd answers, and goes on without
it aloud. Never: the daemon socket, the host's network namespace,
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
has no namespace on the host. `exec` is ssh over vsock:
machined records `SSHAddress` and `SSHPrivateKeyPath` for the VM, and
NixOS installs `systemd-ssh-proxy` into `ssh_config`, so
`ssh -i <key> root@<address>` is the whole transport; `machinectl shell`
answers "Operation not supported" for a VM. Guest side, the sshd dropin
vmspawn ships names `systemd-tmpfiles` and `sshd` bare, which NixOS's
systemd does not find, so `guest.nix` overrides that unit as a dropin
with store paths and a host key made at boot. User and `--setenv` values
come from the record, and
`secretEnv` values are resolved from `/run/secrets` at exec time by the
same path enter uses, since the record holds names and there is no leader
on the host whose environment could be read. A
placement (`--network`) is a tap nixcage makes under its own name
(ADR-013), on the bridge, pinned and isolated (ADR-015) before the guest
boots, and handed to qemu by name through the same extra words the
kernel line goes by; in `modules/veth.sh` beside the veth case, a second
port kind on a bridge, extended, not extracted. vmspawn's own tap would
carry its name, shortened by a hash of its own past fifteen characters,
and on a host running networkd the masquerade systemd ships a network
file for. `--dns` reaches the guest in the credential and is written as
the nspawn rootfs gets it (ADR-016). `--network ns:` is refused: a VM
has no namespace to join.

**7. Refusals before boot.** No `/dev/kvm`; `systemd-vmspawn --version`
below 261 or absent; a conflicting substrate; a missing bridge; a
credential over 32768 bytes, since the SMBIOS structure that carries every
credential holds 64 KiB base64-encoded in all and a 49000-byte one was
measured to take vmspawn's own down with it, silently; the second `enter`
on a running name.
After boot: no readiness from the session unit within the boot timeout
(30 s) is `stop`, exit 124, unless the scope is already gone when the
timeout fires, in which case the VM finished before its readiness was
seen and what it left is read like any other exit. Readiness is a marker
the unit writes and syncs into the home before argv runs, on the share
the status crosses on and by the same means: vmspawn's own `READY=1`
reaches vmspawn and nobody behind it. A missing
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

`systemd-vmspawn` is young and NixOS has no module for it. Four things the
design rested on were a spike on the Linux host before any code or model,
and its answers are in the Verification section: the guest boots with its
root over virtiofs, with the three conditions decision 3 now states;
`machinectl shell` does not reach a VM and ssh over vsock does; the scope
is `machine-<name>.scope` under `machine.slice`, so `scope.sh` holds; and
`--private-users` does not shift `--bind` shares, which is why decision 5
maps by identity. The boot measured 6.7 s for an untrimmed NixOS with a
getty and logind; the claim of under three seconds is against a guest
that carries the session unit and little else, and is checked in the
measurement plan.

ADR-003's statement that host-versus-tool isolation on Linux rests on the
container boundary alone becomes true of the nspawn substrate only. ADR-003
gets an amendment line saying so when this document is accepted; it is not
superseded, since every nspawn cage still lives by it.

The session lifecycle (boot, ready, running, exited, status written, powered
off, stopped by the host, with timeouts and a host that may die) crosses a
VM boundary with more than three states. The formal modeling gate applies:
`models/microvm-session.qnt` states it, with the invariants "the host never
reports success without a status", "no VM outlives its record unseen by
`list`", "stop converges" and "enter never returns with the VM running",
written before the guest unit and the host-side protocol are coded. One
thing in decision 7 comes from writing it: a boot timeout that fires after
the scope is gone reads the status rather than reporting 124. Substrate
resolution is a pure function of four inputs and gets a table, not a model.

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

The claim: a `true` session boots and exits under three seconds with KVM;
the hog is killed and the session returns; a file the guest writes in the
project is owned by the project owner on the host; the credential line
either passes or is refused before boot naming the bound; every other line
behaves as written. Times and outputs are recorded in this
document's Verification section when run.

## Verification

Proposed 2026-09-17.

Spike 2026-09-17, on a NixOS host with systemd 261.2, `/dev/kvm`, qemu
10.2 and virtiofsd from the host's nixpkgs on `PATH`, a guest built from
the same nixpkgs, `systemd-vmspawn --directory=<skeleton>
--linux=<kernel> --initrd=<initrd> --firmware=none --bind=<probe>
--bind-ro=/nix/store --private-users=100000:65536 --register=yes
--set-credential=nixcage.session:hello` with
`SYSTEMD_VMSPAWN_QEMU_EXTRA="-append 'root=root rootfstype=virtiofs rw
init=<toplevel>/init console=hvc0'"`. Four answers. The guest boots:
stage 1 mounts the `root` tag, the `fstab.extra` credential mounts the
store and the probe under `/sysroot` before the closure lookup, stage 2
receives `nixcage.session` and `systemd-creds --system cat` reads it
back; three things were needed for that and are in decision 3 (`init=`
through the qemu extra, `dmi_sysfs` in the initrd, the skeleton owned by
the shift uid). `machinectl shell spike` fails with "Failed to get shell
PTY: Operation not supported"; `ssh -i /run/systemd/vmspawn/spike/ed25519
root@vsock/<cid>` reaches the guest once the sshd dropin is overridden
as decision 6 says, with the cid from `machinectl show -p VSockCID`. The
scope is `machine-spike.scope` in `machine.slice`, leader qemu, and
`machinectl terminate` stops it. virtiofsd got `--translate-uid
map:0:100000:65536` for the root share only; a file guest root wrote into
the probe bind is host uid 0, and guest `nobody` was refused in a host
directory mode 0755 owned by 1000. `systemd-analyze` in the guest: 555 ms
kernel, 2.7 s initrd, 3.4 s userspace. Two things seen on the way: the
host's vmspawn dropin used `systemd-tmpfiles --inline`, which a 258 guest
lacks, so the guest must come from the host's pkgs; and the initrd's
fstab generator logs a duplicate `/sysroot` entry between NixOS's fstab
and vmspawn's, harmless, to be quieted when the guest is written.

Model 2026-09-17: `quint run models/microvm-session.qnt --invariants
successHasStatus scopeHasRecord stopConverges doneMeansGone
crashBeforeSyncIsNoStatus --max-steps=40 --max-samples=100000` finds no
violation; each of three mutants (success reported without a status, rm
of a running cage, a stop that leaves the scope) is found within 5000
traces. A simulation, not a proof: Apalache is not in the dev shell.

Implementing 2026-09-17: `modules/substrate.sh` holds the resolution and
`tests/unit/substrate.bats` its table and refusals; `--substrate` is in
the parse, held to the two names, and refused beside `--shell`.
`modules/vmspawn-args.sh` assembles the line and the credential from the
parse, `tests/unit/vmspawn_args.bats` reads both back word by word;
`--disk` is in the parse, a size, refused on nspawn. Measured on the way:
48000 bytes of credential reach the guest beside vmspawn's own, 49000 do
not, and none of the others do either. `modules/guest.nix` is the guest,
built by `nixcage.microvm.enable` from the host's pkgs and named in the
container config with `nixcage.substrate.default`; `modules/guest-session.sh`
is its unit, and `tests/unit/guest_session.bats` reads the host's
credential back through it. `tests/command/modules.bats` evaluates the
guest. Booted by hand with the assembler's line on this host: argv ran
as the host uid, its file in the home is that uid's, its status 7 came
back through `.nixcage-exit`, the guest powered off, 7.1 s in all; the
console carried argv's output and nothing else once the kernel was told
`loglevel=0` and pinned there by sysctl, systemd told `show_status=0`,
`log_target=null` (a shutdown logging to kmsg raises the console level
back to warnings and prints the power-down line) and `TERM=dumb` (its
init resets the console and marks the boot with OSC sequences
otherwise). `enter` runs the microvm branch: `modules/microvm-session.sh`
holds the refusals, the watch and the outcome, `tests/unit/microvm_session.bats`
drives them on fixtures and a stub `machinectl`; the record carries the
substrate and answers for it (`scope.bats`). On this host, through
`nixcage-container enter --substrate microvm`: argv ran as the owner uid
in `/workspace` with `HOME=/home/nixcage`, wrote a file the owner owns,
saw no daemon socket, and its `exit 3` came back; `true` is 7.9 s wall
against the claim of three, to be trimmed; a second enter with
`--substrate nspawn` was refused naming the record, and one with no flag
ran on microvm by it. The verbs over the running cage, live on this
host: `status` reads `machine-mvtest.scope` with qemu as leader once
`scope.sh` knows vmspawn as a spawner beside nspawn, `list --json` shows
the substrate with the scope, `netns` answers `none`, `exec` reaches the
guest over vsock ssh as the session's uid in `/workspace` with the
session's environment and secrets and returns the command's status, and
`stop` ends the VM, after which enter reports "session ended without
status", 255. The `nixcage` CLI hands `--substrate` through. Agent forwarding, live: a throwaway agent's key listed by `ssh-add -l`
inside the session through `/run/ssh-agent.sock`, and a commit made as
the session's uid, which the guest names from the login name (`nixcage`
without one) in its own passwd, since git refuses a committer that does
not exist. `--disk 1G`, live: the image is made sparse under
`disks/<name>` by `storage ensure` with the size as quota, the guest
makes ext4 on it once and mounts it at `/var/lib` for the session's uid,
a file written there is read by the next session, and the image is
attached to every later session of the cage whether asked for or not,
since it is the cage's as the home is; `rm` removes it with the rest.
`--network nctest0:10.99.0.2/24 --dns 10.99.0.1` on a throwaway bridge,
live: eth0 carries the address, `resolv.conf` the nameserver, the
bridge's address answers a ping, 1.1.1.1 does not, a ping sent as
10.99.0.9 is dropped by the pin, the port is isolated, and the pin and
the tap are gone after the session. Open: `exec` does not carry what enter was asked by
`--setenv`, since the record holds no values; the measurement plan.
`nixcage.cages.<path>.substrate` is rendered as one line per cage into
the container config and read by the project's exact path; live, a
declaration of nspawn ran the cage on nspawn over a record of microvm,
and one of microvm refused `--substrate nspawn` naming the declaration.
