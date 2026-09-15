---
id: ADR-014
title: A cage without the daemon sees the closure of its roots, not the store
status: implementing
date: 2026-09-15
status_date: 2026-09-15
summary: enter --no-nix-daemon binds each path of its roots' closure and nothing else of /nix/store; --store-root names a root
depends_on: [ADR-009, ADR-011]
supersedes: []
superseded_by: []
---

## Context

Every session binds the whole of `/nix/store` read-only. A store is
world-readable and its executables run by full path, so what a session can
execute is not what its `PATH` shows but everything the host's store
holds: every package of every other cage's toolchain, the host's own
services, and every `*-source` a flake evaluation ever fetched, which on a
developer's machine is every repository they have opened. `PATH` is a
convenience; the bind is the boundary.

A session with the daemon needs the whole store: the daemon adds paths
while the session runs and the session has to see them. A session without
it (ADR-011 point 3) needs exactly what it was handed: the base userland
and whatever the caller realised elsewhere and put on `PATH`. Nothing
else it could reach by path is something it was given.

The dependant that asked for ADR-011 is about to share its host's store
into the machine its cages run on, so that a toolchain the host already
holds is not fetched twice. Under the whole-store bind that widens what a
cage can read from one machine's closure to one operator's entire history.
The fix belongs here, because the bind is nixcage's.

## Decision

**1. `enter --no-nix-daemon` binds the closure of its roots and nothing
else of the store.** The rootfs carries an empty `/nix/store`; each path
of the closure is bound read-only at its own name. The roots are the base
profile, the paths a session's own line names (the direnvrc, the
certificate bundle) and every `--store-root`. The closure is computed on
the host with `nix-store --query --requisites`, once per session, before
nspawn runs. `/nix/var/nix/db` is not bound: nothing inside reads it
without a daemon.

**2. `enter --store-root <path>`, repeatable.** A store path the caller
realised and wants the session to see, with its closure: a profile it put
on `NIXCAGE_PATH_PREFIX`, a directory of extensions it bound in. A path
not under `/nix/store` is refused where it is read; a path the host's
store does not hold is refused by the query. With a daemon the option is
accepted and changes nothing, since the whole store is there.

**3. A session with the daemon is unchanged.** The whole-store bind stays
for it, and every session that does not say `--no-nix-daemon` is the
session ADR-011 left, byte for byte. `--print-argv` shows the difference,
so a dependant's seam test sees one `--bind-ro` per path where it saw one
for the store.

**4. What the caller binds by hand is not widened.** A `--bind-ro` of a
store path the caller names is bound as it always was, at the name it
gave; it is not a root and its closure is not added. A caller that wants
a closure says `--store-root`.

## Consequences

A closure of a profile with a JVM toolchain is on the order of a thousand
paths, and each is one `--bind-ro` on the nspawn line and one mount in
the cage. nspawn takes the arguments and the kernel the mounts; the
measurement plan below says what that costs at session start, which is
the one number this design has to stay under. If it does not, the
alternative is one image of the closure built per session and bound as a
single mount, which is a build where this is a query, and is not chosen
here.

Nix inside the session was already unusable (ADR-011 point 3); now the
store it cannot write is also a store it cannot list. `nix path-info` and
its kind fail on the missing db as they failed on the missing socket.

A store path the session reaches only by name, with no root naming it,
was reachable before and is not now. A dependant whose sessions relied on
that reads it in its seam test as a bind that is gone.

## Measurement plan

Session start with a JVM profile as the root, whole-store bind against
closure-only, on the machine the cages run on:

```bash
nix-store --query --requisites /nix/store/<profile> | wc -l   # the count
time nixcage-container enter --no-nix-daemon \
  --store-root /nix/store/<profile> --setenv NIXCAGE_PATH_PREFIX=/nix/store/<profile>/bin \
  probe /path/to/project true
```

The claim is that the closure-only start is within one second of the
whole-store start at a thousand paths. The count and both times are
recorded beside the result in this document's Verification section.

## Verification

Implemented 2026-09-15: `modules/store-closure.sh` holds the root check,
the one query over every root and the bind per path, driven by
`tests/unit/store_closure.bats` with `nix-store` stubbed; `enter
--store-root` is parsed and refused by `modules/enter-args.sh`
(`tests/unit/enter_args.bats`); `modules/container.nix` binds the closure
of the profile, the paths its own line names and the roots when the
daemon is absent, and the whole store otherwise, which
`tests/unit/exports.bats` asserts by shape and the guest script's build
on a Linux builder checks. Open: the measurement above, which needs a
machine with a JVM profile.
