---
id: ADR-004
title: Container sessions run under the project owner's uid, not real root
status: implemented
date: 2026-08-29
status_date: 2026-08-29
summary: nspawn maps the container onto the project owner's uid instead of running sessions as real root
depends_on: [ADR-003]
supersedes: []
superseded_by: []
---

## Context

ADR-003 specified a plain systemd-nspawn container with no user namespaces, so
a session's processes ran as real host root while the project directory
belonged to the invoking user. Testing `enter` on a NixOS host showed that
this combination does not work for the ordinary case.

Nix resolves a flake in a git working tree through its libgit2 fetcher, and
libgit2 refuses to open a repository owned by a different uid than the calling
process:

```
error: opening Git repository "/workspace": repository path '/workspace'
is not owned by current user (libgit2 error code = 7)
```

Every project directory under a workspace root belongs to the user, and nearly
every project is a git repository, so `enter` failed for the normal case. The
failure was not visible from the host, because git accepts the ownership
mismatch when `SUDO_UID` names the owner; nspawn does not forward `SUDO_UID`
into the container, so only the container hit it.

Two narrower repairs were measured and rejected. Setting `safe.directory`, both
as an exact path and as a wildcard, does not lift the check: Nix's libgit2 does
not consult that configuration, and the error is unchanged. Forwarding
`SUDO_UID` to the owner's uid does lift the check, but it leans on a git
heuristic rather than removing the mismatch and leaves the container running as
real root. Rewriting the invocation to `nix develop path:/workspace` also
works, but it changes flake identity: `self` loses `rev` and `shortRev`, and
untracked files and `.git` are copied into the store.

The same mismatch was also the reason a session's output landed in the user's
project as `root:root`, requiring sudo to edit afterwards.

## Decision

The container is mapped onto the owner of the project directory rather than run
as real root.

**1. The uid map follows the project.** `cmd_enter` reads the project
directory's owner and passes `--private-users=<owner_uid>:1`, so the
container's uid 0 is the owner's uid on the host. The project appears to be
owned by root inside the container, and libgit2's ownership check passes
because the ownership genuinely matches.

**2. Ownership shifting stays off.** `--private-users-ownership=off` keeps
nspawn from rewriting ownership on the host. The session rootfs skeleton and
the persistent home are created by root and are chowned to the owner instead,
so they do not appear as an unmapped `nobody` inside the container. The home is
narrowed to mode 0700, since it is the container's `/root` and now belongs to a
named user rather than to root.

**3. One uid is mapped, not a range.** A session needs uid 0 only: builds go
through the host nix daemon, so no `nixbld` range has to exist inside. A range
of one avoids claiming host uids that belong to other users.

This amends the "no user namespaces" clause of ADR-003. The rest of ADR-003
stands, so it is not superseded.

## Consequences

- `enter` works on git projects, which is the normal case. Recorded flake
  revisions, including the `-dirty` marker, resolve inside the container.
- The blast radius shrinks: a session no longer runs as real host root. Its
  capabilities are confined to a user namespace, and an escape yields the
  invoking user's privileges rather than root's.
- Files a session writes into the project are owned by the user instead of
  root, so they no longer need sudo to edit.
- nspawn derives the gid map from the same base as the uid map, so files
  created in a session carry group `<owner_uid>`, which is usually not the
  user's primary group and may name no group at all. This is cosmetic; the
  owner bits govern access. The bind-mount options `rootidmap` and `owneridmap`
  do not repair it, because the group owning a bind-mount source has no effect
  under them and, combined with `--private-users`, they surface the mount as
  `nobody`.
- Containers whose project directory is owned by root behave exactly as before,
  since the mapping is then the identity.
