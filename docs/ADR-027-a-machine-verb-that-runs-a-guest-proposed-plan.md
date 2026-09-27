---
id: ADR-027
title: A machine verb that runs a guest-proposed plan, validated on the host
status: implemented
date: 2026-09-27
status_date: 2026-09-27
summary: nixcage-container plan --machine <name> lets a guest propose an enter or exec line and the host validate and run it
depends_on: [ADR-009, ADR-026]
supersedes: []
superseded_by: []
---

## Context

ADR-026 point 6 keeps closure computation on the host: a machine's guest has
the store without its database, so only `nixcage-container enter --machine`
on the host can resolve a cage's binds. That much is already exported.

What is not exported is the step before it. fabriek's decision to run a
factory in a machine of its own found that composing an `enter` line for a
role needs facts that live only on the machine's disk: the role's worktree
path, its signing key, its `pi` directory, because the machine's guest, not
the host, holds a factory's state. The host cannot compose the line; the
guest cannot run it. fabriek's answer was to split its own `role-enter`: the guest half
prints the `nixcage-container` words it would have run, NUL-separated, to
stdout; the host half reads that plan over `nixcage exec --machine`,
refuses one whose verb is not `enter` or `exec`, refuses one that names
`--auth-sock` (a caller-forwarded socket the guest must not choose for
itself), adds the host's own `--auth-sock` when a person entering gave one,
and only then runs `nixcage-container <verb> --machine <name> ...`.

That validation is a second, independent implementation of a rule that
belongs to nixcage: which verbs a plan may name, which flags a proposer may
not set for itself. A dependant that gets this grammar wrong risks a
machine's root choosing its own `--auth-sock` or naming a verb `enter`
never meant to reach, which is exactly the class of bug ADR-026's "the
guest may be hostile" stance exists to close. Any second dependant that
wants the same shape (propose from where the state is, run from where
the closure is) would have to write the same validator again, or worse,
a laxer one.

## Decision

**1. `nixcage-container plan --machine <name>` reads a NUL-separated argv
from stdin and either runs it or refuses it.** The grammar is fixed and
owned here, not by a dependant: the first word must be `enter` or `exec`;
no word may be `--auth-sock` or `--machine` (the caller's own `--auth-sock`,
when there is one, is appended by `plan` itself, exactly as `role-enter`'s
split does today); every other word passes through unexamined, since
`enter` and `exec` already validate their own flags. A plan naming any
other verb, or naming `--auth-sock` or `--machine` itself, is refused with
the verb or flag named in the message.

**Which machine runs is never the guest's to say.** `plan`'s own
`--machine <name>` argument, given by whoever invoked `plan` on the host,
is the only source of which machine's `nixcage-container` runs; nothing in
the guest's words can change it. Today that holds because `enter`'s and
`exec`'s own parsers have no `--machine` case of their own (a stray one
falls through as a positional and fails cage-name validation), which is
exactly why the refusal above is written down rather than left to that
accident: a later flag added to `enter` or `exec` must not reopen it.

**2. The guest composes the plan; the host runs it.** The pattern is: a
program inside the machine (a dependant's own, per ADR-009's fourth
primitive) does whatever reading of guest-local state it needs and writes
a NUL-separated argv to stdout; the caller pipes that into `nixcage exec
--machine <name> -- <guest program> | nixcage-container plan --machine
<name>` run on the host. `plan` never runs inside a machine: it checks the
`MACHINE_GUEST` declaration flag ADR-026's guest module renders (the same
flag `storage ensure`'s quota refusal reads) and refuses there, since a
plan proposing itself to itself defeats the boundary it exists to hold.

**3. `plan` is the fifth exported primitive.** It sits beside `enter` in
ADR-009's table with the same argv-only shape: pinnable in `flake.lock`,
stubbable in a seam test. It adds no capability a caller lacks: the
caller could already compose and run an `enter` line by hand. It only
moves the composition to where the facts are and keeps the refusal where
the trust boundary is.

## Consequences

fabriek's `role-enter` split becomes a caller of `plan` instead of a
second implementation of its grammar; its own verb/flag refusal is
deleted once `plan` lands and fabriek's lock is bumped (the same
two-commits-two-repositories pattern already used between these
projects).

The grammar is deliberately narrow: two verbs, one forbidden flag. A future
dependant needing a third verb in a plan, or a second forbidden flag,
extends this table rather than writing its own; that is the seam this ADR
cuts. Widening it further than a dependant has actually asked for is not
done here.

`plan`'s refusal is the only new thing `seam.bats`-style tests must cover:
a plan naming a verb outside `enter`/`exec`, a plan naming `--auth-sock` or
`--machine` anywhere in its words, the host's own `--auth-sock` landing
after the guest's words, and `plan` itself refused when `MACHINE_GUEST` is
set. No existing verb's behavior changes; `enter --machine` and `exec
--machine` are unchanged and `plan` is refused inside a machine, so
nothing already running is affected until a dependant opts in by calling
it.

ADR-009's "four primitives and nothing else" is amended by this ADR once
implemented: five primitives, `plan` added to the table beside `enter`,
`uid`, `storage ensure` and `exec`.

## Verification

```bash
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats tests/unit/plan.bats tests/unit/exports.bats
nix develop --command bats --recursive tests/
```

`tests/unit/plan.bats` drives `nixcage_plan_words` and
`nixcage_plan_machine_guest_refusal` directly: an enter and an exec plan
prefixed with the machine `plan` was given, a verb outside `enter`/`exec`
refused, `--auth-sock` or `--machine` refused wherever they appear in the
guest's own words, the caller's `--auth-sock` landing after `--machine` and
before the guest's words, an embedded newline in a guest word surviving
whole, and the machine-guest refusal firing only when `MACHINE_GUEST` is
set. `tests/unit/exports.bats` covers that `plan` is dispatched, sources
`plan.sh`, is in the usage line, and refuses itself inside a machine through
the named refusal. All 12 plan.bats and 24 exports.bats assertions pass; the
full suite (633 assertions) passes with no failures.
