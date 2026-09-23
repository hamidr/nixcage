---
id: ADR-025
title: A host declares the binds a cage always has, and a session still asks for its own
status: implemented
date: 2026-09-23
status_date: 2026-09-23
summary: nixcage.cages.<path>.binds renders a table the session adds to what it was asked for, with a clash refused
depends_on: [ADR-009, ADR-019, ADR-020, ADR-022, ADR-024]
supersedes: []
superseded_by: []
---

## Context

Until 1.2.0 a project had a `nixcage.vm.nix`, and a path a project needed
beyond its own directory went in as a `microvm.shares` entry. One VM per
project made that a per-project statement. The file is gone and nothing
replaced it: what a caller wants mapped in is `--bind SRC:DST` or
`--bind-ro`, per session, every session. The reporter of issue #1 raised it
as the last of four complaints, and it is the only one still standing.

The same shape has arrived twice before. A cage's substrate is declared per
cage (ADR-019) and a cage's bounds are declared per cage (ADR-022), both on
`nixcage.cages.<path>`, both rendered into the declaration as a table keyed by
project path, both read by the session that enters that path. A third
property wanting the same treatment is not a new mechanism; it is the same
one, asked for a third time.

What has held it back is ADR-009 decision 2: a caller says what to map into a
session, and nixcage says whether the destination may be mounted over. A
declared bind puts something into a session whose caller did not ask for it.
That is a real widening and it is decided here rather than left implicit.

## Decision

**1. `nixcage.cages.<path>.binds` declares what a cage always has.** A list
of `SRC:DST` or `SRC:DST:ro`, on the submodule that already carries
`substrate` and `bounds`. It renders into the declaration (ADR-024) as a
`CAGE_BINDS` table, one `<path> <spec>` per line, read by the same reader
every other setting goes through.

**2. The host may add to a session, because it is the host's machine.** The
authority this grants is the authority an administrator already has over
every cage on the machine it administers, and it is the same standing
`nixcage.containerPackages` has today. What changes is that a session now
carries mounts its caller did not name, so a session says what it was given:
`list --json` shows a declared bind beside an asked one, and they are
distinguishable there.

**3. Declared and asked binds are added, not resolved.** A cage's declared
binds come first on the line, the session's own follow, and both go through
`modules/bind.sh` unchanged. Two binds naming the same destination is a
refusal naming both and the cage they collided on, not a silent win for
either: a session mounting something other than what it asked for is the
failure ADR-019 already refuses for a substrate flag against a fixed cage.

**4. A declared bind is held to the shape at evaluation and to the policy at
the session.** The module refuses at evaluation what is a typo rather than a
decision: a spec that is not `SRC:DST` or `SRC:DST:ro`, a path that is not
absolute, a path with a `..` segment. What a destination may be stays
`bind.sh`'s answer at the session, because duplicating that list in Nix would
be the second implementation ADR-024 exists to prevent. A host learns about a
malformed bind at `nixos-rebuild switch` and about a refused one at the first
`enter` of that cage.

**5. Undeclared, there is no equivalent, and that is said.** A host that
declared nothing has no cage table, so `nixcage_declaration_reset` gives
`CAGE_BINDS` its empty value and `nixcage enter --bind` is the whole answer.
`nixcage status` already lists what an undeclared host does not have, and
this joins that list.

**6. The host module only.** On macOS a bind's source is resolved inside the
VM, which is shared only the workspace roots (ADR-002), so a declared bind
naming a path outside them would be declared and broken. Widening what the VM
sees is a decision about what the VM is, not about what a bind is, and it is
not made here.

## Consequences

ADR-009's line moves, and this document is where to find that it moved. A
dependant that builds a session out of flags now gets a session that may hold
more than its flags said, on a host whose administrator declared it. The
alternative was that a host with something to say about one cage had to say
it to every caller of that cage separately, which is not a boundary, only an
inconvenience.

A third table in the declaration, after the substrates' and the bounds'.
Three tables with one grammar between them is the point at which the grammar
should be one thing rather than three copies; that is not this document's
change, but the next property to want a table should make it.

A 1.2.0 user gets `microvm.shares` back in the place where a host says things
about a cage, at the cost of it being the host's file rather than the
project's. A user who wants it without a module keeps the flag: ADR-023's
mode is for trying nixcage, and a setting worth remembering is a host worth
declaring.

The refusal in decision 3 can be met by a caller who did nothing wrong, when
a host declares a destination that a dependant has been passing for months.
It is still the right outcome: the two statements disagree about what the
session is, and neither of them is nixcage's to discard.

## Measurement

No size or time claim. What is checked is the behaviour, at both ends:

```
nix develop --command bats --recursive tests/
# the table renders, the parse reads it, a clash refuses, a bad spec fails eval

nix build .#checks.x86_64-linux.cage
# a declared bind is in the session, and a session reads the file through it
```
