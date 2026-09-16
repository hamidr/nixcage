---
id: ADR-016
title: A bridged cage resolves nothing unless told where
status: proposed
date: 2026-09-16
status_date: 2026-09-16
summary: enter --dns none|<address> decides the cage's resolver; a private-network session defaults to none, not the host's file
depends_on: [ADR-011]
supersedes: []
superseded_by: []
---

## Context

The rootfs a session gets carries a copy of the host's `/etc/resolv.conf`,
made before the network is decided. For a session in the host's namespace
that is the right file. For a cage placed on a bridge (ADR-011 point 1), or
one joining a placed cage's namespace (ADR-011 point 5), it names a
resolver the cage cannot reach: the host's resolver is off the bridge's
subnet and the cage has no route to it. Every lookup inside such a cage
waits for the resolver's timeout and then fails, which is a slow failure
with a misleading message where an immediate one was available.

The dependant met this on a machine as a slow start nobody attributed: a
program that looks a name up before doing anything else stalled for the
resolver timeout, and the stall read as the program's. Its answer was to
turn the lookups off in the program, which is the right answer for that
program and no answer for the next one.

What a private-network cage should resolve with is the caller's to say. A
caller that runs a resolver on the bridge names it; one that runs none
wants the cage to fail at once, with `Could not resolve host`, rather than
late.

## Decision

**1. `enter --dns none|<address>`.** `none` writes an empty
`/etc/resolv.conf` into the rootfs; an address writes `nameserver
<address>` and nothing else. The address is one IPv4 address, refused where
it is read if it is anything else.

**2. A private-network session defaults to `none`.** With `--network` of
either shape and no `--dns`, the file is empty. A session in the host's
namespace keeps the host's file, as it has since ADR-002, so a session that
asks for neither option is the session ADR-009 exported.

**3. `--dns` without `--network` is refused.** A session in the host's
namespace resolves as the host does; a caller that wants otherwise has a
different question, and refusing is better than a file the host's resolver
would contradict.

## Consequences

`modules/enter-args.sh` grows one option and one refusal; the guest script's
rootfs block writes the file from the parse rather than copying it. A
caller that runs a resolver on the bridge names it, which the dependant
does not yet do and does not need to.

A cage with an empty `resolv.conf` and glibc falls back to loopback, which
in a private namespace answers nothing, so the failure is immediate. That
is the behaviour wanted and it is glibc's, not ours; a libc that behaves
otherwise is the caller's to know about.

## Verification

`tests/unit/enter_args.bats`: `--dns none` and `--dns 10.0.0.1` parse with
a bridge placement and with a namespace path; a name, a port, or an IPv6
address is refused; `--dns` without `--network` is refused in either order;
a parse inherits no resolver from the last one. The rootfs check the
no-daemon suite already does is extended: a private-network rootfs carries
an empty file, a named one carries one `nameserver` line, and a
host-namespace rootfs carries the host's file byte for byte.
