---
id: ADR-007
title: A linked git worktree binds its git directory into the session
status: implemented
date: 2026-09-01
status_date: 2026-09-01
summary: sessions bind the git directories a linked worktree points at, so git works in a worktree instead of failing outright
depends_on: [ADR-002]
supersedes: []
superseded_by: []
---

## Context

A session binds exactly one project path: `--bind="$project:/workspace"`.
That is enough for an ordinary repository, whose `.git` is a directory inside
the project and therefore inside the bind.

It is not enough for a linked git worktree. There, `.git` is a file holding an
absolute pointer into the primary repository:

```
gitdir: /home/user/repo/.git/worktrees/repo.feat
```

That path is outside the project bind, so it does not exist inside the
container. Reproduced by making the target unreachable, which is what the
container namespace does:

```
$ git status --short
fatal: not a git repository: (null)     # exit 128
```

Every git command fails, including the ones an agent depends on to see what it
has changed and to commit it. Nothing in the session reports why: the project
looks like a checkout, `git` is on `PATH`, and the failure names no path.

This matters more than the worktree count suggests. Tools that run several
coding agents in parallel give each one its own worktree of the same
repository; that is the shape of the workload nixcage exists to isolate. Under
those tools every single session is a worktree, so the tool works only for
repositories nobody runs more than one agent against.

Two directories are involved, and both must be reachable. The administrative
directory named by the pointer holds the worktree's own `HEAD` and index. The
common directory it names in turn, through a `commondir` file that is usually
the relative path `../..`, holds the objects and refs shared with every other
worktree. Binding only the first leaves git without objects.

## Decision

A session binds the git directories its project points at, in addition to the
project itself.

- `nixcage_git_binds` resolves them: absent or directory `.git` needs nothing,
  a `.git` file yields the administrative directory and, through `commondir`,
  the common one. When the administrative directory sits inside the common one,
  which is git's own default layout, a single bind covers both.
- The binds use the exact path spelling git recorded, normalized only for `.`
  and `..`. Git resolves its pointers textually against paths it wrote itself,
  so a symlink-resolved twin of the path would not be the path git opens.
- They are read-write. A worktree writes its `HEAD` and index in the
  administrative directory and its objects and refs in the common one, so a
  read-only bind would permit reading history and nothing else. Committing is
  the point.
- A project that claims to be a worktree but whose pointer leads nowhere fails
  the session. Entering with a silently broken git is worse than refusing: the
  agent would work for an hour and be unable to record any of it.
- Resolution lives in `modules/git-worktree.sh`, sourced by store path into
  `nixcage-container`, following `modules/dev-shell.sh`: a real shell file that
  shellcheck reads and the bats suite sources directly.

## Consequences

The container's view of the filesystem now extends past the project directory.
The primary repository's whole `.git` is writable in the session, which means
every branch, every object, and the reflog of a repository whose working tree
the session was not given. For a worktree that is the intended trust boundary,
since the worktree can reach that history through git in any case, but it is
the first bind nixcage adds that is not the project.

The bound path can also sit outside every configured workspace root, because
`check_workspace_root` validates the project path and the primary repository is
wherever the user put it. A workspace root is no longer the outer edge of what
a session can write to.

On macOS the bind resolves inside the VM, so the primary repository must be
reachable there under the same absolute path. A worktree under a workspace root
whose primary repository is not gets a clear failure rather than a broken git.

Identity is still missing. The container has no `/etc/gitconfig` and a fresh
per-project `/root`, so `git commit` fails for want of a name and an email
until something supplies them. That is a separate decision about what of the
host's identity a cage may carry, and it is not made here.
