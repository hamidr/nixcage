---
id: ADR-025
title: A bind is asked for per session, and nothing declares one on a caller's behalf
status: accepted
date: 2026-09-23
status_date: 2026-09-23
summary: no per-cage bind option and no caller-owned registry; the flag is the interface and repetition is the caller's to solve
depends_on: [ADR-002, ADR-009, ADR-020, ADR-024]
supersedes: []
superseded_by: []
---

## Context

Until 1.2.0 a project had a `nixcage.vm.nix`, and a user who wanted a host
path inside the cage wrote it there as a `microvm.shares` entry. One VM per
project made that a per-project statement. The file is gone, the VM is one
per machine on macOS and one per cage on Linux, and nothing replaced that
sentence: what a caller wants mapped in is `--bind SRC:DST` or `--bind-ro`,
per session, every session.

The reporter of issue #1 met this as the last of four complaints, and it is
the only one still standing. The other three are answered: a project needs no
`flake.nix` (ADR-021), a host needs no module (ADR-023), and a cage can have
a kernel of its own again (ADR-019).

The pressure is not only theirs. Every property that wants to be per-cage has
arrived separately and been plumbed separately: the substrate (ADR-019), the
bounds (ADR-022), and now binds would be the third. That is the shape of a
missing concept, and it is worth saying once why this particular one is not
built rather than answering it again each time it surfaces.

Two homes were considered and are recorded here so the next reader does not
have to reconstruct them. The first is the host module, extending the
submodule that already carries `substrate` and `bounds` with a `binds` list
keyed by project path, rendered into the declaration (ADR-024) as another
table. The second is a registry the invoking user owns, outside both the
project and the host, holding what a flag would have said.

## Decision

**1. A bind is a session's, asked for at `enter`, and nothing remembers it.**
The record holds what a cage is (its name, uid, subject, placement, home and
store roots); it does not hold what one session mounted. The next `enter`
without the flag has no such mount, and this is the behaviour, not an
omission.

**2. No `nixcage.cages.<path>.binds`.** It would work, it is small, and it is
declined on what it does to ADR-009 rather than on cost. That decision draws
the line at: a caller says what to map into a session, and nixcage says
whether the destination may be mounted over. A declared bind puts something
in a session whose caller did not ask for it and cannot see why it is there.
`nixcage.containerPackages` already crosses that line, and its own
justification is that `enter` takes binds and environment and never packages,
so there is otherwise no way to put one there. Binds have a way. The
exception does not generalise to the case it was written to exclude.

**3. No caller-owned registry either.** ADR-024 has just collapsed four
rendered files into one declaration with one reader, so that an option has
one place to state what it means, declared and undeclared. A second
declaration read from the caller's home would immediately mean two
precedence stories, two undeclared answers, and two places to look when a
session is not what somebody expected. The saving, one flag not retyped, does
not buy that.

**4. Repetition is the caller's to solve, and the two ways are enough.** A
person writes a shell alias or a wrapper: `alias cage='nixcage enter --bind
~/.cache/models:/models'`. A program passes the flags it already builds, which
is what a dependant does with every call it makes, and is why this has never
been a problem for cageworks.

**5. What a 1.2.0 user does instead of `microvm.shares`.** On Linux, one
`--bind` per path, on the `enter` that wants it. On macOS the path must
already be inside a workspace root, because a bind's source is resolved where
the cage runs and the VM is shared only those roots (ADR-002). That
difference is documented in the README and the spec rather than fixed: fixing
it means giving the VM module a way to share a path the roots do not cover,
which is a different decision about what the VM is, not about what a bind is.

**6. What would reopen this.** A second independent report of the same need,
or a dependant that cannot express what it wants through the flags. One
reporter who also refuses the module is not enough evidence to grow a second
configuration surface, and saying so here is cheaper than deciding it again.

## Consequences

Issue #1's last row stays open, and a 1.2.0 user who wants their per-project
paths back retypes a flag or writes an alias. That is the cost, and it is
paid by the people most likely to have used the removed file.

A per-cage concept remains absent while three of its properties exist
separately. If a fourth arrives, this document is evidence for building the
concept rather than plumbing the fourth: the argument here is against a
declarative bind, not against ever having a cage declaration.

`--bind` stays the only way in, so its checks stay load-bearing:
`modules/bind.sh` refuses a destination that is not absolute, one spelt with
a `..` segment, the rootfs, anything under `/nix` or `/etc/nixcage`, and
nspawn's own API mounts. Nothing here relaxes them, and a bind that crosses
into a microVM keeps ADR-020's staging.

Nothing in the code changes. This document exists so that the next time the
question is asked, the answer is a reference rather than a rediscovery.
