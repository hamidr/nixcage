---
id: ADR-021
title: A project is any directory under a workspace root, not only a flake directory
status: implemented
date: 2026-09-22
status_date: 2026-09-22
summary: enter validates the workspace root alone; a directory with no flake.nix opens the base container shell
depends_on: [ADR-002, ADR-005]
supersedes: []
superseded_by: []
---

## Context

ADR-002 defined a project as any flake directory under a workspace root, and
`enter` enforced the flake half of that definition before anything else:

```
[nixcage] No flake.nix in /home/user/Projects/foo -- a nixcage project is any flake directory.
```

ADR-005 already retreated from the stricter version of the same idea. A flake
without `devShells.default` used to be refused; it now opens the base container
userland, on the reasoning that "the container is what the user came for" and
that most directories in a real workspace do not declare a shell. The flake
file itself was left as the admission ticket, and nothing was re-examined when
ADR-019 added a second substrate: a microVM session evaluates the project flake
through the same `nixcage_enter_shell` and is refused for the same reason.

The gate buys no mechanism. `modules/dev-shell.sh` chooses an environment by
probing: `.envrc` first, then the flake's devShell attributes, then the base
userland. Nothing else in a session reads `flake.nix`. The one thing the gate
does buy is a clear message, and it is a message that says no to a session that
would otherwise have worked.

It is also not the only gate. `nixcage_has_dev_shell` evaluates the project
with `builtins.getFlake`, which fails on a directory with no flake exactly as
it fails on a flake that does not evaluate. So removing the host-side check
alone moves the refusal inward and degrades it: the caller is told the flake
failed to evaluate and sent looking for an error that was never printed.

The report that prompted this (issue #1) was a user with ordinary project
directories, who read the requirement as nixcage asking to be let into a flake
it had no business in.

## Decision

**1. A project is any directory under a workspace root.** `enter` validates the
workspace root and nothing about the flake. The root stays the boundary: it is
host-declared, and it is what says which paths a cage may be opened on.

**2. The absence of a flake is answered before the probe, not by it.**
`nixcage_enter_shell` tests for `flake.nix` ahead of `nixcage_has_dev_shell`
and enters the base container shell, announced, on the same footing as ADR-005's
missing-devShell fallback and ADR-011's missing-daemon one. A flake that fails
to evaluate is still refused: that is a defect to fix, not an environment to
substitute, and the two cases stay apart.

**3. An `.envrc` still wins.** It is the project saying what its environment is,
and it need not mention a flake at all, so a flakeless directory with an
`.envrc` goes through direnv as it always did.

**4. `rm` without a name asks the same question.** Removing the cage of the
directory it was run from used to require a `flake.nix` there to decide the
directory was a project at all; it asks the workspace root instead, which also
replaces a `Usage:` line with the reason.

**5. A session that names a devShell in a directory with no flake is refused,
naming the flake.** `devShells.<name>` is a flake attribute; there is nothing to
fall back to that the caller would accept, and the refusal says `no flake.nix`
rather than reporting an evaluation that never ran.

## Consequences

A mistyped `cd` under a workspace root now opens a cage instead of being caught
by the flake check. That check was never a safety property -- the workspace root
is -- but it did catch typos, and it no longer does.

The base container userland becomes the common case rather than the exception,
which raises the cost of it being thin. It carries a shell, nix, git and little
else, and a caller entering a flakeless directory sees that and nothing more.

`nix develop` is no longer implied by entering a cage, so the phrase "a nixcage
project is any flake directory" leaves README, PRD-001 and ADR-005's context.

Nothing changes for a project that does declare a flake: the probe order, the
devShell fallback and the named-shell refusals are as they were, which
`tests/unit/dev_shell_detection.bats` and `tests/unit/named_shell.bats` hold in
place. The new behaviour is `tests/unit/flakeless_project.bats`, and the host
side is `tests/command/enter.bats` and `tests/command/rm.bats`.

This does not address the other half of issue #1: `enter` still requires
`nixosModules.host` to be imported on a Linux host, so `nix run
github:hamidr/nixcage` remains not a way to use it. That gate is ADR-003's and
is unchanged here.
