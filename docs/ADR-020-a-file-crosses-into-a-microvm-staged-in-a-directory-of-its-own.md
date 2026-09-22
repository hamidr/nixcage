---
id: ADR-020
title: A file asked as a bind crosses into a microVM staged in a directory of its own, and lands where the same enter on nspawn puts it
status: implemented
date: 2026-09-22
status_date: 2026-09-22
summary: a file bind works on microvm; the host stages a copy in a shared directory and the guest binds it onto its target
depends_on: [ADR-009, ADR-019]
supersedes: []
superseded_by: []
---

## Context

ADR-019 put a second substrate behind the one `enter` (ADR-009): the
microVM path takes the binds `modules/bind.sh` produces as vmspawn takes
them, and vmspawn shares each over virtiofs, which shares directories and
nothing else. ADR-019's decision 5 said as much, and `enter_microvm`
refused a bind whose source was not a directory aloud, rather than mount
nothing at its target.

A dependant does not choose its binds by substrate. fabriek composes one
session line and asserts it whole, and that line binds six single files
into a role's cage: its signing key, its bus password, its forge token,
the factory's declaration, the decider's policy, and the loop's entry
files. On nspawn every one lands where the session's environment says it
is. On microvm the first of them was refused on 2026-09-22 (`not a
directory, and only a directory crosses into a microvm:
.../keys/backend`), and a role declared `substrate = "microvm"` never
came up. The alternative in the dependant, laying every role's files in
one directory and binding that, changes the session line for every role
on every substrate, and puts one role's secrets beside each other in one
directory, to work around what the substrate cannot spell. The gap is
the substrate's and closes here (fabriek's ADR-018: what the cage cannot
express changes in nixcage first).

## Decision

**1. A regular file asked as a bind is staged.** `enter_microvm` names
each `--bind` or `--bind-ro` whose source is a regular file
(`nixcage_vmspawn_file_binds`, `modules/vmspawn-args.sh`: number, source,
target, mode, in the order given), copies it with its owner and mode kept
into `<state>/<cage>/session-<pid>.bind/<n>/file`, and shares that
directory read-only at `/run/nixcage/bind/<n>` in the guest. The staging
directory is a sibling of the session's skeleton and never inside it,
since the skeleton is the guest's root share; it is removed with the
skeleton at exit. A directory passes through with its source resolved, since nspawn
follows a symlink given as a source and virtiofsd refuses to share one
(`EINVAL` entering its sandbox, on a directory that was a symlink into
the store). A socket, a device or anything else is still refused before
boot, with the refusal now saying what does cross.

**2. The guest puts each file where it was asked for.** The credential
gains a `files` array (`n`, `dst`, `ro`), written from `--file=N:ro|rw:DST`
words the credential assembler takes beside `--setenv`. The guest's
session unit (`nixcage_session_files`, `modules/guest-session.sh`) makes
the target's directory, touches the target so a bind has a mountpoint,
binds `/run/nixcage/bind/<n>/file` onto it, and remounts it read-only when
the host asked for `--bind-ro`; all before argv runs, after the disk.
What argv finds at the target is the file, owned as on the host, as the
same enter on nspawn gives it.

**3. A copy, not a live view.** virtiofs shares a directory tree, so the
file that crosses is the staged copy taken when the session starts. On
nspawn a bound file is the host's own inode and a write on the host is
seen inside. A session's files (a key, a password, a token, a rendered
declaration) are read once at its start, and a substrate that sees a
snapshot of them is the substrate's edge, stated here rather than closed
with a bind mount on the host that an interrupted session would leak. A
`--bind` (read-write) of a file is staged the same way and its writes stay
in the copy; a dependant that needs them back binds the directory.

**4. The words for exec are unchanged.** The `--file` words go into the
credential only; `exec` keeps the asked environment as before
(`nixcage_microvm_env_write`) and never sees them.

**5. exec on a microVM cage reads the session's home from the record.**
ADR-019's decision 6 took the session's group from the home under the
state directory, which is the home only when nobody asked for another;
a session entered with `--home` (a dependant's every role) got "has no
home" from `exec`. The record (ADR-017) gains `home` when one was asked,
`exec` reads it and falls back to the default, and a record from before
reads as before.

**6. A session without a tty reads a pipe that waits.** ADR-019's
decision 3 ran such an argv on `/dev/null`, which ends at once. The
caller of an nspawn session holds its stdin open, and a supervisor's
argv (pi in rpc mode) reads it for a client and ends on its end, so
every microVM boot of a supervised role ended within seconds of
starting. The guest opens a fifo for reading and writing and gives argv
that as stdin (`nixcage_session_stdin`): a pipe nobody writes and nobody
closes, as the supervisor's is.

## Consequences

A dependant's session line is one line for both substrates, files
included; fabriek's `seam.bats` keeps asserting it whole. The credential
grows by a few dozen bytes per file, under ADR-019's bound. A file bound
read-write into a microvm is a copy whose writes are lost with the
session, which decision 3 states.

Verified by the suite: `tests/unit/vmspawn_args.bats` (a file is named,
a directory is not; the credential carries the files) and
`tests/unit/guest_session.bats` (the mount words per file, none without).
Both scripts build, which is where their shellcheck runs. On a host:
fabriek's `tests/manual/isolation.sh` substrate scenario on the factory
that declared a microvm role, which is what found the gap.
