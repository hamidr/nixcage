---
id: ADR-024
title: A host renders one declaration, and one reader answers from it, undeclared included
status: proposed
date: 2026-09-23
status_date: 2026-09-23
summary: one versioned file replaces the four under /etc/nixcage, read by one function with two implementations
depends_on: [ADR-003, ADR-009, ADR-017, ADR-022, ADR-023]
supersedes: []
superseded_by: []
---

## Context

A host tells nixcage what it wants through four rendered files, and nixcage
reads them in four places.

`modules/host.nix` renders `/etc/nixcage/config` (`WORKSPACE_ROOTS`),
`/etc/nixcage/container` (`PRINCIPAL_UID_BASE`, `PRINCIPAL_UID_SIZE`,
`PRINCIPAL_SUBJECTS`, `STORAGE_DATASET`, `HOST_PLATFORM`,
`SUBSTRATE_DEFAULT`, `CAGE_SUBSTRATES`, `BOUNDS_DEFAULT`, `CAGE_BOUNDS`,
`MICROVM_GUEST`), `/etc/nixcage/secret-env` (one `VAR=secret` line per pair)
and `/etc/nixcage/gitconfig` (a git config file). `modules/nixcage.nix`
renders the same set for the VM, minus the workspace roots, which reach the
CLI through the build-time cache instead. On the reading side,
`host_read_config` in the CLI parses one of them by hand,
`nixcage_declaration_read` sources another, `write_secret_env` parses the
third, and the session copies the fourth.

Every option added since has paid this twice: once as a rendering and once as
a parse. ADR-022's bounds needed `BOUNDS_DEFAULT` and a `CAGE_BOUNDS` table
with a line grammar of its own, beside `CAGE_SUBSTRATES`, which has another.
ADR-023 then added a third implementation of the same question, namely what a
setting means where nothing was declared, and its own Consequences section
asked for what this document decides: "the declaration is one thing the code
asks rather than a spelling scattered through it: a single reader with two
implementations ... Retrofitting this after `[ -f /etc/nixcage/... ]` has
spread through the script costs far more than writing it this way now."

There is also a seam nobody has had to think about yet. The CLI and the
module are one repository but not one installation: `nix profile install
github:hamidr/nixcage` puts a CLI on a machine whose NixOS configuration
pins an older nixcage, so a CLI can meet a declaration rendered by a
different version of itself. Today that is harmless, because the CLI reads
one key from one file. Under ADR-023 it stops being harmless: a CLI that
does not find what it expects concludes the host declared nothing, and a host
with workspace roots would silently get `$PWD` as its boundary.

## Decision

**1. One file, `/etc/nixcage/declaration`, replaces the four.** Both modules
render it, with the same keys they render today and one more: a
`DECLARATION_VERSION` as its first line. Its grammar stays `KEY=value` lines,
because that is what a shell reads without a parser and what both readers
already expect; this document moves and unifies the file, it does not change
what a value looks like.

**2. One reader answers every question about it, and a question has one
answer where nothing was declared.** `modules/declaration.sh` already holds
`nixcage_declaration_read` and `nixcage_declaration_refusal` (ADR-023); it
grows into the whole of it, and both the CLI and the guest script use it
rather than parsing anything themselves. A new option is added in two places
only: the module that renders it, and the one line in the reader that says
what it means undeclared.

**3. `/etc/nixcage/profile` stays what it is.** It is a symlink to a store
path, not text, and the session resolves it with `readlink -f`. A store path
inside a `KEY=value` line would be the same thing said worse.

**4. The git identity becomes two fields, and the session renders the file.**
`GIT_USER_NAME`, `GIT_USER_EMAIL` and `GIT_SIGNING` replace the rendered
`/etc/nixcage/gitconfig`. The session already renders exactly that file from
exactly those fields when a caller names them (ADR-023 decision 11), so this
deletes the second implementation rather than adding one, and a declared host
and an undeclared one stop differing in how a session gets an identity.

**5. Secrets become one field.** `SECRET_ENV="VAR=secret VAR2=secret2"`
replaces `/etc/nixcage/secret-env`. A secret's name is an attribute name and
a variable's name is checked as one (ADR-009), so neither can hold a space,
and the pair list is a word list. What the session does with it is unchanged:
values are read from `/run/secrets` at session time and never appear in argv.

**6. A declaration this nixcage does not recognise is a refusal, not an
absence.** The reader answers "declared" or "not declared" today; it will
answer "declared", "not declared", or "declared by something I cannot read",
and the third refuses, naming the version it found and the version it wants.
A host that declared workspace roots must never be treated as a host that
declared nothing, which is what a version-blind reader would do the first
time the format changes.

**7. The files this replaces are read when the new one is absent, and the
session says so.** A CLI newer than the module it stands on finds
`/etc/nixcage/config` and `/etc/nixcage/container` where it expected
`/etc/nixcage/declaration`, reads them as it does today, and prints once that
it is reading a declaration from an older nixcage and that
`nixos-rebuild switch` will produce the current one. The compatibility path
is removed one release after this lands, and until then it is the only thing
that makes a partial upgrade safe.

## Consequences

The migration touches both modules, the CLI, the guest script and the parts
of the suite that write fixtures for `/etc/nixcage/*`. That is a large
mechanical change for no new behaviour, which is exactly why it is worth
doing before the next option rather than after it: every option added from
here pays the old design twice, and the undeclared answer pays it a third
time.

The compatibility path in decision 7 is a second reader living beside the
first, which is what decision 2 exists to abolish. It is accepted on a clock:
it is written as one function that translates the old files into the new
keys, not as a second set of call sites, and it is deleted on the next
release. If it outlives that, this document has failed at the thing it is for.

`HOST_PLATFORM` remains a rendered value rather than something the guest
script detects, because it says which platform's nixcage rendered the
declaration, not which kernel is running.

Nothing here reaches a dependant. The four primitives (ADR-009) are argv on a
program and their flags do not change; what changes is where that program
reads a host's answers from. A dependant that has been reading
`/etc/nixcage/container` itself, which nothing documents and nothing
promises, would break, and that is the correct outcome.

An undeclared host gains nothing and loses nothing: ADR-023's behaviour is
already the reader's second implementation, and this makes that structural
rather than incidental.

## Measurement

This asserts no size or time claim. What it does assert is that the four
files stop being read in four places, and that is checked rather than
believed:

```
grep -rn "/etc/nixcage/" nixcage modules/
# after: modules/declaration.sh and the two modules that render, nothing else

nix build .#checks.x86_64-linux.cage
nix build .#checks.x86_64-linux.primitives
# both boot a machine with a module-rendered declaration and enter cages on it

nix develop --command bats --recursive tests/
```

The compatibility path of decision 7 is checked by the same NixOS test with
the declaration removed and the two old files written in its place, which is
the state a partial upgrade produces.
