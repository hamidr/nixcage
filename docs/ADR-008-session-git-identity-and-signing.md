---
id: ADR-008
title: Sessions commit under a declared identity and sign through the forwarded ssh-agent
status: implemented
date: 2026-09-01
status_date: 2026-09-01
summary: sessions get a declared git identity and sign through the forwarded ssh-agent, holding no key of their own
depends_on: [ADR-007]
supersedes: []
superseded_by: []
---

## Context

ADR-007 made git work inside a session. It did not make `git commit` work.

A container has no `/etc/gitconfig` and a per-project `/root` that starts
empty, so git has no committer name or email and refuses to record anything.
Nothing in nixcage supplied one: the host environment is deliberately never
read, and no option declared one either.

Signing is the second half. On the machine that prompted this, `commit.gpgsign`
and `tag.gpgsign` are true with `gpg.format = ssh`, so a commit without a
signing key fails outright:

```
fatal: either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured
```

An agent that can edit a project but cannot commit is close to useless: the
work exists only as a dirty tree, no branch can be handed back, and the session
cannot be the unit of work it is meant to be.

The delegation is real and was decided deliberately. A session that can sign
produces commits that verify as the user, including commits the user never
read. The narrower alternatives were declined: unsigned commits inside cages
with signing left to the host, and a separate cage key added to
`allowed_signers` so agent work is attributable and revocable on its own. Full
parity was chosen.

Given that, the question was only how the key reaches the session. Two ways
were considered. As a sops secret the private key would be written into every
session at rest, on the VM data volume and in the session filesystem, readable
by anything running there for as long as it exists. Forwarded as an agent
socket no key material crosses the boundary at all, the capability lasts only
as long as the session, and `git-config(5)` supports exactly this: with
`gpg.format = ssh` and `user.signingKey` unset, git calls
`gpg.ssh.defaultKeyCommand` and signs with the first key the agent offers.

## Decision

A session gets a declared identity and signs through the invoking user's
ssh-agent.

- `nixcage.git.userName`, `nixcage.git.userEmail`, and
  `nixcage.git.signing.enable` (default true) render `/etc/nixcage/gitconfig`
  through `container.gitConfigText`, alongside the existing
  `/etc/nixcage/{profile,secret-env}`. Both platform modules render it, and
  neither renders anything unless both name and email are set: half an identity
  would replace git's own clear error with a stranger one.
- The rendered config names no key. `gpg.ssh.defaultKeyCommand = ssh-add -L`
  leaves the choice to whatever the forwarded agent holds, so rotating a key
  needs no nixcage change.
- `nixcage enter` passes `--auth-sock` when `SSH_AUTH_SOCK` is set and the
  socket exists. On Linux the path is passed explicitly, since sudo strips the
  variable. On macOS the CLI adds `ssh -A` and leaves `$SSH_AUTH_SOCK`
  unexpanded for the remote shell, because the socket that matters is the
  forwarded one inside the VM, not the one on the host.
- `nixcage-container` binds that socket to `/run/ssh-agent.sock`, sets
  `SSH_AUTH_SOCK`, and chowns the socket to the project owner. The container is
  mapped onto that uid (ADR-004), while a forwarded socket belongs to the ssh
  login user, and a unix socket is checked against the caller's real uid.
- `openssh` joins the container profile: `ssh-keygen` produces the signature and
  `ssh-add` names the key.
- A session entered with no reachable agent still enters. Signing then fails at
  commit time, which is the same outcome as running git anywhere else without a
  key, and refusing the session would make the cage unusable offline.

## Consequences

A cage can sign as the user. Any agent inside one can produce commits and tags
that verify as them, on any branch of any repository the session can reach.
That is the delegation that was asked for, and it is not reversible after the
fact: a signature the user did not intend looks exactly like one they did.

Agent forwarding is wider than signing. The socket answers any request the
agent will answer, so a session can also authenticate as the user to any host
their keys open: push to remotes, pull private repositories, ssh out. Nothing
here scopes it to git. Narrowing it means running a per-session agent loaded
with the signing key alone, which this decision does not do.

Signature verification inside a cage does not work. `gpg.ssh.allowedSignersFile`
lives on the host and is not rendered, so `git log --show-signature` reports
that it needs to be configured. Signing is unaffected; only reading back is.

Entering a session now mutates something outside the container: the ownership
of the forwarded socket. On Linux the socket already belongs to the invoking
user and the chown is a no-op. In the VM it belongs to the ssh login user and
the change lasts as long as the forwarded socket, which is the session.

## Verification

`nix eval` of the host module renders the expected gitconfig. A commit made
with that rendering, against a real agent and no key on disk, carries an
`SSH SIGNATURE` header, which is the assumption the whole decision rests on.
The CLI's forwarding is covered by bats on both platform paths: the socket is
passed when one exists, and neither `-A` nor `--auth-sock` appears when it does
not. The rendering itself is Nix configuration and carries no bats test, per
the infrastructure tier.
