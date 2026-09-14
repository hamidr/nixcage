---
id: ADR-012
title: A cage has a scope, and nixcage answers for it
status: proposed
date: 2026-09-14
status_date: 2026-09-14
summary: status, netns and stop for a running cage from the scope nspawn gives it; memory and cpu bounds set on it at enter
depends_on: [ADR-009, ADR-011]
supersedes: []
superseded_by: []
---

## Context

ADR-011 point 5 let a session join the network of a cage already running,
and left which pid that cage is to the caller: "the caller's to know, as
the address was". The dependant knows it the only way it can, by
`pgrep` for the `--machine=<name>` word over the process table and the first
child of what it finds. That reads nspawn's argv, which is not an
interface, and it is the reaching-around ADR-009 exports primitives to
end. The same dependant has no way to stop a session that stops answering
except to reach for the process table again, and no way to bound what a
session may take of the machine's memory and cpu: a cage today is bounded
by the machine alone, and one JVM inside one cage can take the rest of the
cages' memory with it.

Two facts, from nspawn's own manual, decide the shape. A container runs in
a transient scope unit unless `--keep-unit` is passed; `--register=no`
disables registration with machined and nothing else, so every cage
nixcage starts already runs in `machine-<name>.scope` under
`machine.slice`. And `--property=` sets unit properties on exactly that
scope, "useful to set memory limits and similar for the container". The
scope exists, has the cage's name, holds every process of the cage in its
cgroup, and accepts limits. What is missing is nixcage saying so.

## Decision

**1. Three verbs over a running cage, from its scope.**

- `nixcage-container status <name>` prints `running <leader-pid>` or
  `stopped`, from `systemctl show machine-<name>.scope` and the scope's
  `cgroup.procs`. The leader is the cage's first process: the one whose
  parent is nspawn, which is the one in the container's namespaces.
- `nixcage-container netns <name>` prints `/proc/<leader>/ns/net`, the
  path `enter --network ns:` takes, or fails when the cage is not running.
- `nixcage-container stop <name>` stops the scope, which ends every
  process of the cage, and waits for it to be gone.

**2. Two options on `enter`, set as properties of that scope.**
`--memory <size>` becomes `--property=MemoryMax=<size>`, `--cpus <n>`
becomes `--property=CPUQuota=<n*100>%`. A size is digits with an optional
`K`, `M`, `G` or `T`; cpus is a positive integer. Absent, the cage is
bounded as before, by the machine.

**3. The scope is the cage's identity for the host.** Its cgroup path,
`machine.slice/machine-<name>.scope`, is what a host that attributes
events to cages keys on; nixcage prints it in `status` so a caller never
composes it. Every process a cage starts is in it, whatever uid it takes.

**4. ADR-011 point 5 is amended.** Which pid a running cage is stays a
fact the caller needs; it is now a fact nixcage tells.

**5. `--keep-unit` stays out.** It would move the cage into the caller's
own unit, disable `--property=`, and make the cage's identity whatever
started it. The scope nspawn allocates is the right one.

## Consequences

`modules/scope.sh` holds the verbs' logic as functions over a cgroup root
and a proc root, so the suite drives them on fixtures rather than on a
running cage; `enter-args.sh` grows two options and their two refusals;
the guest script gains three verbs and two properties on the nspawn line.
`systemctl` enters the guest script's closure by store path.

A dependant that found the leader by `pgrep` deletes that code and asks.
A dependant that could not stop a cage can, and one that could not bound a
cage can, one word each.

Scope names are nspawn's: a cage name is escaped into a unit name the way
systemd escapes, which for the alphabet `check_name` allows (`[a-zA-Z0-9-]`)
is the identity. That alphabet is why no escaping is written here; a wider
one would need `systemd-escape`.

`status` reads the scope through `systemctl`, so the verbs work only on a
host with systemd, which is every host nixcage runs cages on.

## Verification

```bash
nix develop --command bats tests/unit/scope.bats tests/unit/enter_args.bats
nix develop --command shellcheck nixcage modules/*.sh
nix build .#nixcage
```

`tests/unit/scope.bats` drives `modules/scope.sh` on a fixture cgroup and
proc tree: a running cage's leader and namespace path, a stopped cage, a
name that is no cage, and the words `stop` runs. `enter_args.bats` gains
the two options, their properties, and the refusals for a size that is not
one and a cpu count that is not one. What needs a machine is one session
started with `--memory 256M` running a process that takes more, seen
killed, and `status`, `netns` and `stop` asked of it; recorded here when
run.
