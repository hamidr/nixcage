---
id: ADR-006
title: A project with an .envrc is entered through direnv
status: implemented
date: 2026-08-31
status_date: 2026-08-31
summary: sessions run direnv when the project has an .envrc, so those projects get the same environment as on the host
depends_on: [ADR-005]
supersedes: []
superseded_by: []
---

## Context

ADR-005 made the devShell optional, but a project still had exactly two
possible environments: whatever `nix develop` produces, or the container's bare
userland. A container's environment is otherwise fixed -- nspawn starts from
nothing and the guest script sets `HOME`, `PATH`, `NIX_REMOTE`, `NIX_CONFIG`,
`NIX_SSL_CERT_FILE` and `TERM`, plus whatever `nixcage.secretEnv` maps. The
host environment is deliberately never read.

That leaves out how a large share of projects actually declare their
environment. On the machine that prompted this, 12 of 43 project directories
carry an `.envrc` while only 21 have a `flake.nix`, and the host has
`nix-direnv` enabled, so on the host those projects get their environment by
entering the directory. In a container they got nothing: `.envrc` was not read,
so no `PATH_add`, no `export`, no `use flake`, and a project whose devShell
exists only behind `use flake` fell all the way through to the bare shell.

## Decision

A session whose project has an `.envrc` is entered through direnv.

- `direnv` joins the container userland profile, and the guest passes
  nix-direnv's `direnvrc` in as `NIXCAGE_DIRENVRC`.
- `nixcage_enter_shell` checks for `.envrc` before probing the flake. The
  `.envrc` is the project stating what its environment is, so it wins; in
  practice the two usually agree, since most of these files are one `use flake`
  line.
- `nixcage_seed_direnvrc` appends a `source` line for nix-direnv's stdlib to
  `~/.config/direnv/direnvrc` in the persistent home, once. This is what makes
  `use flake` cache the devShell profile and hold a gcroot on it; without it
  every entry re-evaluates the flake and the VM's weekly collection drops the
  closure between sessions.
- The `.envrc` is allowed automatically before running. direnv refuses one it
  has not been told to trust, and there is no one to ask inside a container.
- An `.envrc` that fails, meaning direnv itself exits non-zero, stops the
  session. It is not replaced by a devShell or a bare shell, for the same
  reason ADR-005 gives for a flake that does not evaluate.

Rejected alternatives:

- Probing the devShell first and using direnv only as a fallback: it would
  ignore an `.envrc` that does anything besides `use flake`, which is the case
  that motivated this.
- Requiring the user to run `direnv allow` inside the container: the first
  session of every project would open in the wrong environment, and the prompt
  cannot be answered non-interactively.
- Plain direnv without nix-direnv: `use_flake` exists in direnv 2.37's stdlib,
  but without the caching one the VM's gc makes every session pay a full
  devShell rebuild.

## Consequences

Projects configured with direnv now behave inside a container as they do
outside it, which is the property that makes a container a drop-in place to
work rather than a separate environment to maintain.

Automatic `direnv allow` is a real grant: the `.envrc` is arbitrary shell that
runs at session start. It is bounded by the container, which sees one project,
its own home and a read-only store, and the session was opened on that project
deliberately. A user who does not want that should not enter the project.

One failure mode is not ours to control. When an `.envrc` says `use flake` and
that devShell fails to build, nix-direnv prints "Evaluating current devShell
failed. Falling back to previous environment!" and exits zero, so the session
opens in a degraded environment rather than stopping. Observed on a project
whose devShell has a fixed-output hash mismatch. This is nix-direnv's own
behaviour and it is what the host does too, which is the consistency this ADR
is for; the alternative would be a nixcage-specific divergence from the tool
the project is configured against. ADR-005's guarantee therefore covers the
flake path, and on the direnv path it stops at direnv's exit status.

direnv and nix-direnv are now in every container's closure, whether or not the
project uses them.

`~/.config/direnv/direnvrc` in the persistent home is written by nixcage. A
user who puts their own contents there keeps them; the seed only appends its
`source` line when absent.

## Measurement plan

The decision table is covered with direnv and nix stubbed:

```
nix develop --command bats tests/unit/direnv_session.bats
```

Six cases pass: direnv takes precedence over the devShell, the command is
passed through, the `.envrc` is allowed first, nix-direnv is wired in, seeding
is idempotent, a project without `.envrc` still takes the devShell path, and an
`.envrc` that exits non-zero is not replaced by a bare shell.

Lint and the whole suite stay clean:

```
nix develop --command shellcheck nixcage modules/dev-shell.sh
nix develop --command bats --recursive tests/
```

End to end, a project whose `.envrc` exports a variable has it in the session:

```
cd <project with .envrc> && nixcage enter -- sh -c 'echo $PATH'
```

shows the environment the `.envrc` builds rather than the bare profile path.
