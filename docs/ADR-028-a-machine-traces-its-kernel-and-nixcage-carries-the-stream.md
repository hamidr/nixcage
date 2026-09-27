---
id: ADR-028
title: A machine traces its own kernel with bpftrace, and nixcage carries the stream, not its meaning
status: proposed
date: 2026-09-27
status_date: 2026-09-27
summary: one bpftrace producer per machine, fanned out over a Unix socket nixcage owns; the caller keeps all labeling and policy
depends_on: [ADR-009, ADR-012, ADR-017, ADR-026]
supersedes: []
superseded_by: []
---

## Context

fabriek already traces its own machine's kernel: one `bpftrace` unit in its
host module (`modules/host.nix`), reading `probes.bt` (exec, exit,
tcp_connect, cgroup-filtered in-kernel), piped into `fabriek-container
probes-publish`. It works because a factory's roles share one machine's
kernel (ADR-026): one producer covers every cage in it, each event
cgroup-tagged so the consumer attributes it to a role.

The question that came up is whether this belongs to fabriek alone, or
whether nixcage should carry it as a primitive any dependant can reach,
the way `status`/`exec`/`list` already are (ADR-009, ADR-012, ADR-017).
Two things pushed toward carrying it: the producer-per-machine shape is
already forced by the kernel boundary ADR-026 drew, not by anything
fabriek-specific; and a second dependant would otherwise re-derive the
same systemd unit and cgroup-filter idiom fabriek already has.

bpftrace can also act, not just observe: `signal()` reaches into a traced
process directly. That is a different blast radius (new privilege, not
new visibility) and is out of scope here; nothing below builds toward it,
and nothing below forecloses it.

## Decision

**1. One bpftrace producer per machine, not per cage.** A machine is the
kernel boundary (ADR-026); cages inside one share it. `nixcage-container
machine trace start <machine>` runs one `bpftrace` process against the
machine's kernel, filtered by cgroup as fabriek's `probes.bt` already is.
Starting it twice for the same machine is a no-op onto the existing
producer, not a second process.

**2. The stream carries raw kernel events only.** nixcage supplies the
producer and the transport; it does not label an event with a role, a
factory, or any caller's vocabulary. A cgroup id is the only key on the
line, exactly as ADR-012 already treats a cgroup as a cage's scope. What a
cgroup id means to the caller is the caller's business, same boundary
ADR-009 already draws around the four primitives.

**3. Transport is a Unix socket, fanned out to N consumers.** The producer
writes to `$STATE/<machine>/trace.sock`; nixcage owns a small broadcaster
between bpftrace's stdout and the socket, since bpftrace itself has no
multi-consumer concept. `nixcage-container machine trace attach <machine>`
connects and streams raw lines to stdout. A second, concurrent attach
(fabriek's own consumer, plus a person watching live) is the reason for a
socket over a one-shot pipe under `exec`: fabriek's `probes-publish` and an
operator's `attach` can both be live on the same producer.

**4. Lifecycle rides the machine's, not a new one.** The producer starts on
`machine trace start` or lazily on first `attach`, and stops on `machine
down` alongside the guest's own teardown; the socket path goes with it.
Nothing about a cage's own `enter`/`stop`/`rm` changes: this is a verb on
the machine (ADR-026), not on a cage.

**5. No enforcement.** The producer only ever pipes `bpftrace`'s text
output; no `signal()`, no `system()`, in the probe program nixcage ships.
A dependant wanting enforcement writes its own probe program against this
same producer/socket shape; nixcage's contribution stops at carrying
whatever text a probe program emits.

## Consequences

nixcage takes on a background process and a socket per machine that did
not exist before: something to start idempotently, tear down on `machine
down`, and recover if the machine restarts without a clean shutdown. This
is the same shape ADR-026's guest lifecycle already manages, extended, not
a new lifecycle class.

fabriek's existing `modules/host.nix` unit and `probes.bt` become
redundant once this ships: fabriek would point `probes-publish` at the
socket instead of running its own `bpftrace` unit. Migration is fabriek's
call, on its own schedule; nothing here requires it.

The default probe program (exec, exit, tcp_connect, cgroup-filtered) is
carried over unchanged from fabriek's own; widening it is a probe-program
change, not a nixcage change, and does not require touching this ADR.

Native (non-microvm) substrate is out of scope: bpftrace needs same-kernel
access to the traced cgroups, which a machine's guest kernel gives by
construction (ADR-026) but a native cage sharing the host kernel raises a
different question (tracing host-wide from inside nixcage's own process,
not a guest's) not addressed here.
