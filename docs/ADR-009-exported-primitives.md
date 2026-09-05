---
id: ADR-009
title: nixcage exports four primitives and nothing else
status: accepted
date: 2026-09-05
status_date: 2026-09-05
summary: a session, a principal's uid, owned storage and a way to reach the cage host are the whole interface a dependant sees
depends_on: [ADR-002, ADR-003, ADR-004]
supersedes: []
superseded_by: []
---

## Context

nixcage grew a second thing inside it: a factory of named roles working one
repository. The two shared a repository, a CLI, a NixOS module, an option
namespace and a guest script, and they were not the same tool. That factory has
left to become cageworks, which takes nixcage as a flake input.

Something has to be left behind in its place. The factory did not sit on top of
nixcage; it reached into it. It wrote nspawn arguments directly, ran `zfs`
itself, and allocated uids out of nixcage's own range. Every one of those was a
special case inside `nixcage-container` that existed for one caller, and
nothing marked where the cage ended and the caller began.

The question this document answers is not whether to have an interface -- the
split forces one -- but how small it can be while a factory still fits on top
of it, and what shape it takes so that a dependant can be pinned to it and a
test can stand in for it.

## Decision

**1. Four primitives, each argv on a program.** Argv is what `flake.lock` can
pin and what a test can stub. A sourceable shell library was the alternative and
is rejected: it would bind a dependant to nixcage's internal function names,
give the boundary no version to break at, and let a renamed helper break a
dependant silently.

- *A parameterised session.* `nixcage-container enter` takes `--uid`, `--user`,
  `--home`, `--bind SRC:DST`, `--bind-ro SRC:DST`, `--setenv K=V`, `--shell
  NAME` and `--no-agent` alongside the `--auth-sock` it already had. Every one
  of them existed as a special case inside the script before this document, so
  what is exported is a description of working code rather than a design.
- *A principal's uid.* `nixcage-container uid <principal>` allocates from the
  range `nixcage.principalUidRange` declares, monotonically, never reissuing a
  number. What a principal is stays the caller's: nixcage promises only that
  one name always answers with one number.
- *Owned, bounded storage.* `nixcage-container storage ensure <path> <uid>
  [quota]` gives a dataset where the host has a pool and an ordinary directory
  where it does not. Which of the two it is stays nixcage's decision, and the
  caller is not told which it got.
- *A way to reach the cage host.* `nixcage exec [--tty] [--agent] --
  <argv...>` runs argv as root where the cages are: on this machine on Linux,
  and inside the shared VM over its SSH on macOS. It is on the CLI rather than
  on the guest script because it is what carries a caller to the guest script.
  Without it the other three are reachable only on Linux, and a dependant would
  have to read nixcage's SSH key, port and state layout to reach a macOS VM.

**2. A caller names paths and principals; nixcage names datasets and numbers.**
The line falls in the same place three times. A caller says which directory it
wants owned and how much it may hold; whether that is a dataset is nixcage's.
A caller says which principal wants a uid; which number that is, is nixcage's.
A caller says what to map into a session; whether the destination may be
mounted over is nixcage's.

**3. The widened input surface is checked rather than trusted.** `--bind` maps
any host path into a cage, where before only code that knew about roles could
add one. It grants no authority the caller lacks, since that caller already
runs as root outside every cage and could invoke `systemd-nspawn` itself. But
the check that was implicit in "only nixcage's own code adds binds" is now
explicit: `modules/bind.sh` refuses a destination that is not absolute, one
spelt with a `..` segment, the rootfs itself, anything under `/nix`, anything
under `/etc/nixcage`, and nspawn's own API mounts. `--setenv` names are checked
for the same reason; values are not, because any byte is a legal value.

**5. The option parser is a shell file, not a loop inside the Nix string.**
`modules/enter-args.sh` holds it, so the suite sources it and drives the
interface directly. An interface nothing can drive is one that breaks at a
dependant's run time instead of at ours, and this one is the whole point of
the document.

**4. The uid store is renamed in place, not recreated.** It was `role-uids`
while the factory lived here. Renaming it without moving it would reallocate
every number, and a reissued uid hands something new the files of something
dead, which is the one property the store exists to prevent.

## Consequences

nixcage stops having an opinion about what is built on it. The word "role" does
not appear in this repository any more, and the code that used to know about
factories now knows about principals, paths and binds.

A dependant needing a new flag becomes two commits in two repositories and a
lock bump. That cost is the boundary; paying it is how the interface stays
small. Bisecting a regression across the seam gets harder for the same reason.

The interface is guessed once and lived with. The mitigation is point 1: every
flag existed as working code before it was named an export.

`nixcage exec` is a named capability where there was an unnamed one. Entering a
project has always run argv as root on the cage host for anyone who could run
the CLI; what changes is that this can now be reasoned about instead of being a
side effect of `enter`. It is not a shell -- argv is passed through word for
word, and on macOS every word is quoted for the remote shell exactly as a
session command already was.

The Formal Modeling Gate does not fire. No invariant changes: uid allocation
keeps the property it had, the bind check is a predicate over one string, and
`enter` composes arguments it used to compose inline. What moved is which
program decides, not what is decided.

## Verification

```bash
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats --recursive tests/
```

`tests/unit/enter_args.bats` drives the parser of point 1,
`tests/unit/bind.bats` covers every refusal in point 3,
`tests/unit/storage.bats` and `tests/unit/principal_uid.bats` cover point 2,
and `tests/command/exec.bats` covers the transport. `tests/unit/exports.bats`
asserts what is left over: that every verb is still dispatched and that no flag
the parser accepts is missing from the usage line a caller reads at run time.

The guest script itself is a Nix string, so it exists only once built. Building
it runs the shellcheck `writeShellApplication` does:

```bash
nix build --impure --expr 'let f = builtins.getFlake "<your config flake>"; \
  in f.nixosConfigurations.nixcage.pkgs.callPackage \
     (import ./modules/container.nix) {}'
```
