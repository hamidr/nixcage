---
id: ADR-010
title: A cage maps a block of uids, and a session need not be root
status: proposed
date: 2026-09-07
status_date: 2026-09-07
summary: a principal gets a contiguous block rather than one number, so a cage can hold subjects that do not trust each other
depends_on: [ADR-004, ADR-009]
supersedes: []
superseded_by: []
---

## Context

ADR-004 decided that one uid is mapped and not a range, for two reasons that
were right at the time: a session needs uid 0 only, since builds go through the
host nix daemon and no `nixbld` range has to exist inside a cage, and a range
of one avoids claiming host uids that belong to other users.

That single uid is also the session's identity, and the two jobs are not the
same job. `nixcage_principal_login` writes a named principal into `/etc/passwd`
at uid 0, so `--user` renames root rather than replacing it. A cage has exactly
one subject and it is always root.

A dependant now wants two subjects in one cage that do not trust each other
equally: a supervising process, and a program it supervises that runs whatever
code it is asked to. Under one uid they are one principal. The supervised
program can open the supervisor's sockets, signal it, read its files and write
as it, so nothing the supervisor records about the supervised program is worth
more than the supervised program's cooperation.

Two subjects cannot be two calls to the existing primitive. nspawn maps a
contiguous host range and `nixcage_principal_uid` hands out `highest + 1`
across all principals, so two names get two numbers that land wherever they
land. Contiguity has to come from the allocator or it does not exist.

That same packing is the hazard in getting this wrong. Principals allocated
under ADR-004 sit shoulder to shoulder, so widening what a cage maps without
widening what it was allocated hands every cage its neighbours' uids.

ADR-004's second reason survives and argues only against a wide range. Uids
come from `nixcage.principalUidRange`, which is declared and reserved, so
claiming a few more inside it takes nothing from anybody. Its first reason
survives untouched: nothing here adds a `nixbld` range or a build user.

## Decision

**1. A host declares the subjects a cage has.** `nixcage.principalSubjects` is
a list of names, empty by default. Cage root is always subject 0 and is not in
the list, so a host that declares nothing gets a block of one and behaves
exactly as it does today. The block size is derived from the declaration rather
than configured beside it, because two numbers that must agree eventually will
not.

**2. A principal is allocated a whole block.** The uid store gains a size
column, and the cursor is the highest `base + size` rather than the highest
base. An entry written before this change has no size and reads as one, which
is what it was, so an existing host upgrades without any principal's block
overlapping the neighbour it was packed against. The exhaustion guard moves
with the cursor and tests the block's end: a guard on the base alone admits a
block that starts inside the declared range and ends outside it.

**3. A principal keeps the block it was allocated.** A principal allocated when
no subjects were declared holds one uid, and declaring subjects later does not
widen it: blocks are fixed at allocation, since widening one in place would
walk into whatever was allocated next. Giving subjects to such a principal
means a new principal and chowning what the old one owned. Numbers are never
reissued, so the old block stays claimed and its files stay traceable.

**4. `uid` answers for a subject as well as a principal.**
`nixcage-container uid <principal> [<subject>]` returns the principal's base
with no subject and that subject's number with one. A caller never adds an
offset to a base, which keeps ADR-009's line where it is: a caller names
principals and subjects, and nixcage names numbers.

**5. `enter` maps the block** with `--private-users=<base>:<size>`, and writes
`/etc/passwd` and `/etc/group` entries for every declared subject so ids
resolve to names inside the cage. This amends ADR-004's third clause and
nothing else in it.

**6. A session may run as a subject rather than as cage root.**
`enter --subject <name>` starts the command under that subject, with `--home`
naming that subject's home. The default is cage root, which is what runs today,
so no existing caller changes.

**7. Cage root keeps `CAP_SETUID` over its own block and reaches nothing
beyond it.** A supervisor therefore enters as cage root and starts what it
supervises under a subject, rather than dropping first: once it has dropped it
cannot start anything, and a supervisor that cannot restart what it supervises
is not one. Two subjects are enough for that, and the property it buys is that
the supervised program can neither signal the supervisor nor open what the
supervisor owns.

**8. `storage ensure` is unchanged and is called with a subject's number.**
Which subject owns a path is the caller's decision and the caller now has a way
to name it.

## Consequences

Host uid consumption multiplies by the block size, so a declared range holds
proportionally fewer principals and the existing exhaustion error arrives
sooner. That error already names the option to widen. A host that declares no
subjects consumes exactly what it does today, so this costs nothing until it is
asked for.

**Ownership becomes a choice rather than a fact.** `--private-users-ownership=off`
means host files must already carry the mapped uid, and ADR-004 exists because
libgit2 refuses a repository owned by a different uid than the process opening
it. With one subject there was nothing to decide. With a block, whichever
subject owns the workspace fixes which subject may run nix in it, and a session
entered under a different subject than the one owning the tree gets ADR-004's
original error back. This is the sharp edge of the change.

The container-side uid is an offset into the block, since nspawn maps container
uid 0 upward onto the host range. A subject that looks like an ordinary Linux
account at 1000 therefore costs a block of 1001, which is affordable inside a
widened range and buys nothing that a name at offset 1 does not: nothing inside
a cage reads the `>= 1000` convention, because `/etc/passwd` is written by
`make_rootfs` and there is no login stack to consult it.

A session that is not cage root is a session whose home is not `/root`, which
touches everything keyed on that path: the home bind, direnv's state, and the
profile a shell resolves.

ADR-009's interface gains no primitive. `enter` gains a flag and `uid` gains an
optional argument, and both keep the line that document draws. A dependant that
keys a firewall rule or an ACL on a uid can now name the subject that needs it
rather than the cage that contains it.

The cage stops being a place where the session is necessarily root, which was
never a security property (the mapping made it the owner's uid on the host) but
was a convenience. Anything inside a cage that assumed it could write outside
its own home without asking will find out here.

## Design gates

The Formal Modeling Gate fires: this is an allocation problem whose invariant
spans every entry in the store. `models/uid-blocks.als` states the cursor and
the guard as promises rather than as arithmetic, and asserts that no two
blocks overlap and that no block leaves the declared range.

```bash
alloy6 exec models/uid-blocks.als
```

Both checks are UNSAT for 4 allocations at bitwidth 6, and the two bug shapes
the model keeps beside them are SAT at 3, so neither check is vacuous. The
guard clause in point 2 is there because of the second one.

## Verification

```bash
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats --recursive tests/
```

`tests/unit/principal_uid.bats` asserts the allocator's promise: one name
answers with one number across calls, a principal and a subject answer with the
number the block says, two principals get blocks that do not overlap, an entry
written without a size reads as one and the block after it starts clear of it,
and an exhausted range still fails with the message naming the option to widen.
`tests/unit/enter_args.bats` gets the mapping and the subject flag, since what
`enter` composes is what a dependant sees.

Point 7 is reasoned from how user namespaces work and is not yet measured. It
is the claim the rest of the document rests on, so it moves this ADR off
proposed only once a test on a real host shows cage root reaching a uid inside
its block and failing to reach one outside it.
