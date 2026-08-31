---
id: ADR-005
title: A project without a devShell enters the base container shell
status: implemented
date: 2026-08-31
status_date: 2026-08-31
summary: sessions probe the flake and fall back to the base container shell when it defines no devShell
depends_on: [ADR-002]
supersedes: []
superseded_by: []
---

## Context

A project is any flake directory under a workspace root, and the guest script
has always ended a session setup with an unconditional `exec nix develop`. That
made `devShells.default` a hard requirement rather than an interface a project
opts into. Entering a flake without one produced only nix's own resolution
error:

```
error: flake 'git+file:///workspace' does not provide attribute
'devShells.aarch64-linux.default', 'devShell.aarch64-linux',
'packages.aarch64-linux.default' or 'defaultPackage.aarch64-linux'
```

The session then exited. In a real workspace most directories are in this
state: of 43 project directories on the machine that prompted this, 21 have a
`flake.nix` and fewer still define a shell. The container is what the user came
for, and refusing to open one because the project has not declared its
dependencies inverts that.

Reading `nix develop`'s exit status to decide when to fall back does not work.
It fails identically when a flake has no devShell and when a flake does not
evaluate, so a fallback keyed on it would drop a project with a broken flake
into a working-looking bare shell and hide the breakage.

## Decision

Sessions choose their environment by asking the flake what it offers, in
`modules/dev-shell.sh`, sourced into the container by store path.

- `nixcage_has_dev_shell` evaluates the flake and reports three outcomes: a
  devShell exists, the flake evaluates and offers none, or the flake failed to
  evaluate. The attributes it asks about are the same four `nix develop`
  resolves, so every project that works today keeps its devShell.
- `nixcage_enter_shell` enters the devShell on the first outcome, and on the
  second announces the fallback on stderr and execs the container's base
  userland, which already provides bash, coreutils, nix, git and cacert. On the
  third it refuses and returns non-zero, leaving nix's error as the last word.

The logic lives in a shell file rather than inside the `writeShellApplication`
string so that shellcheck reads it and the bats suite sources it directly; the
guest script keeps the nspawn mechanics.

Rejected alternatives:

- Falling back on `nix develop`'s exit status: cannot distinguish a missing
  devShell from a broken flake, which is the whole difficulty.
- Synthesising a devShell for such projects: nixcage installs nothing into
  containers, and guessing a project's dependencies is exactly what the
  devShell interface exists to avoid.
- Running direnv in the container and letting `.envrc` decide: a larger change
  that replaces the devShell interface rather than making it optional, and it
  needs `direnv allow` solved non-interactively. Worth revisiting on its own.

`flake.nix` is still required to enter, so ADR-002's definition of a project is
unchanged. Only the devShell inside it becomes optional.

## Consequences

Any flake directory under a workspace root is now enterable, which is the
behaviour the isolation was built for: a project gets a cage before it gets a
dependency set. The base shell is deliberately spare, so a session that needs
tools still wants a devShell, and the message on entry says which situation the
user is in.

Detection costs one `nix eval` of the project flake per session, before the
devShell build that already dominates startup. It uses `builtins.getFlake`,
which reads the working directory where `nix develop` reads the git tree, so a
devShell defined in an untracked `flake.nix` is detected and then fails to
build. That is the same failure the user would get today, reported by nix.

## Measurement plan

The unit suite covers the decision table, with `nix` stubbed:

```
nix develop --command bats tests/unit/dev_shell_detection.bats
```

Ten cases pass, covering each of the four resolved attributes, all three
outcomes, and the refusal to fall back on a broken flake.

Lint and the full suite stay clean:

```
nix develop --command shellcheck nixcage modules/dev-shell.sh
nix develop --command bats --recursive tests/
```

End to end, a flake directory with no devShell opens a shell instead of
failing:

```
cd <project without devShells.default> && nixcage enter -- true
```

exits zero after printing the fallback notice, and a project that has a
devShell still enters it.
