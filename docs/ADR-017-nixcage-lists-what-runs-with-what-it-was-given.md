---
id: ADR-017
title: nixcage lists what runs, with what each cage was given
status: implemented
date: 2026-09-16
status_date: 2026-09-16
summary: list --json reports each cage's name, uid, subject, placement, scope and leader from state nixcage recorded at enter
depends_on: [ADR-011, ADR-012]
supersedes: []
superseded_by: []
---

## Context

`nixcage-container list` prints the names under the state directory, which
is every cage that was ever entered and not removed, running or not. What
a running cage was given is spread across three places: the uid and subject
in the argv the caller composed, the placement in the caller's own plan, and
the scope and leader in the cgroup and proc trees ADR-012 reads for
`status`. A dependant that needs all of them for one cage reads its own plan
for two, asks `status` for one, and keeps a table of its own for the rest.

The dependant does this three times: its kernel probes map a uid back to a
role, its session composer asks whether a role's cage runs before deciding
between `enter` and `exec`, and its isolation proof needs each cage's address
and port. Each keeps a copy of a fact nixcage had at enter and threw away.

## Decision

**1. `enter` records what it was given.** Under the cage's state directory,
`placement` holds the uid, the subject, the bridge and address if placed,
and the roots if daemonless, as one JSON object written before nspawn
starts. It outlives the session: the next `enter` under the name overwrites
it and `rm` removes it, so a stopped cage still says what it was given.

**2. `list --json` joins the record with the scope.** One object per name
under the state directory: the recorded fields, and when the cage runs, its
scope's cgroup path and its leader's pid as ADR-012 reads them. A cage
without a record, entered before this document, lists with its name and
scope alone.

**3. `list` without `--json` is unchanged.** One name per line, as before.

## Consequences

`modules/scope.sh` gains a reader over the state directory beside the
cgroup and proc roots it already takes, so the suite points it at fixtures.
The record is nixcage's and read-only to a dependant; a dependant that
edits it edits a file that the next `enter` overwrites. A session joining
a running cage's namespace (ADR-011 point 5) has a name of its own and so a
record of its own, carrying the same address; two records at one address
are a cage and a hand inside it, not a collision.

The record holds the address the caller passed and the uid it allocated,
neither secret. It holds no bind paths and no environment, which a caller
may consider its own; a later document may add them if asked.

## Verification

`tests/unit/scope.bats`: over fixtures, a running cage with a record lists
every field; a stopped cage with a record lists without scope and leader; a
cage without a record lists with its name; the output is one JSON object per
line, parseable by `jq -c`. `tests/command/enter.bats`: the record exists
after enter with the fields the argv named, is still there after the
session, and is gone after `rm`.

Implemented 2026-09-16: `modules/scope.sh` writes the record
(`nixcage_scope_record_write`) and lists it with the scope
(`nixcage_scope_list_json`), both over a state directory the suite
points at fixtures in `tests/unit/scope.bats`, the fixture scenarios above
included; `modules/container.nix` writes the record as soon as the cage's
directory exists, before nspawn, and dispatches `list --json`, which
`tests/unit/exports.bats` asserts by shape, since the guest script's
`enter` needs root and nspawn and `tests/command/enter.bats` drives the
host CLI, not it. A session joining a running cage's namespace records
the namespace path rather than an address, since the path is what it was
given. The guest script builds on a Linux builder.
