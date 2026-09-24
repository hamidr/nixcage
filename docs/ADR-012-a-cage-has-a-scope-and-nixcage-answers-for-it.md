---
id: ADR-012
title: A cage has a scope, and nixcage answers for it
status: implemented
date: 2026-09-14
status_date: 2026-09-24
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
nixcage starts already runs in a scope of its name under `machine.slice`:
`machine-<name>.scope` when machined registers it, `<name>.scope` under
systemd 261 with `--register=no`. nixcage asks which is active rather
than assume one; a caller reads the cgroup from `status` and composes
nothing. And `--property=` sets unit properties on exactly that
scope, "useful to set memory limits and similar for the container". The
scope exists, has the cage's name, holds every process of the cage in its
cgroup, and accepts limits. What is missing is nixcage saying so.

## Decision

**1. Three verbs over a running cage, from its scope.**

- `nixcage-container status <name>` prints `running <leader-pid>` or
  `stopped`, from `systemctl show` on the cage's scope and the scope's
  `cgroup.procs`, or `payload/cgroup.procs` under it where systemd 261's
  nspawn puts the cage. The leader is the cage's first process: the one
  whose parent is nspawn, which is the one in the container's namespaces;
  nspawn itself may sit in the scope or outside it.
- `nixcage-container netns <name>` prints `/proc/<leader>/ns/net`, the
  path `enter --network ns:` takes, or fails when the cage is not running.
- `nixcage-container stop <name>` stops the scope, which ends every
  process of the cage, and waits for it to be gone.

**2. Two options on `enter`, set as properties of that scope.**
`--memory <size>` becomes `--property=MemoryMax=<size>`, `--cpus <n>`
becomes `--property=CPUQuota=<n*100>%`. `MemoryMax=` bounds the RAM a cage
holds and not its swap: on a host with swap a cage past its bound swaps
rather than being killed, and that is the bound (decided 2026-09-24; a
kill would turn a JVM that swaps briefly into a cage that dies). A size is digits with an optional
`K`, `M`, `G` or `T`; cpus is a positive integer. Absent, the cage is
bounded as before, by the machine.

**3. The scope is the cage's identity for the host.** Its cgroup path,
`machine.slice/<scope>`, is what a host that attributes events to cages
keys on; nixcage prints it in `status` so a caller never composes it,
and the spelling of the scope is nixcage's to know. Every process a cage starts is in it, whatever uid it takes.

**4. A command inside a running cage.** `nixcage-container exec
[--subject <name>] <name> [-- cmd...]` enters every namespace of the
leader, the user one included, where joining grants full capabilities,
and runs the command with the leader's own environment in
`/workspace`, as cage root or, with a subject, as that subject's offset
through `setpriv` the way a session becomes it. A hand beside a running
actor is then inside the actor's cage, not beside it.

**5. ADR-011 point 5 is amended.** Which pid a running cage is stays a
fact the caller needs; it is now a fact nixcage tells.

**6. `--keep-unit` stays out.** It would move the cage into the caller's
own unit, disable `--property=`, and make the cage's identity whatever
started it. The scope nspawn allocates is the right one.

## Consequences

`modules/scope.sh` holds the verbs' logic as functions over a cgroup root
and a proc root, so the suite drives them on fixtures rather than on a
running cage; `modules/exec-cage.sh` holds the words that put a command
inside; `enter-args.sh` grows two options and their two refusals; the
guest script gains four verbs and two properties on the nspawn line.
`systemctl`, `nsenter` and `setpriv` enter the guest script's closure.

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
started with `--memory 256M` running a process that takes more, held to
256M of RAM, and `status`, `netns` and `stop` asked of it.

Run 2026-09-24 on a NixOS host (systemd 261, 68.9G swap), nixcage 5.1.5:

```
nixcage enter --memory 256M -- bash -c 'x=$(head -c 400M /dev/zero | tr "\0" a); sleep 20'
# scope while it held the 400M:
memory.max=268435456  memory.current=268398592
memory.swap.max=max   memory.swap.current=420065280
```

RAM held at the bound, the rest in swap, the process not killed: the
bound as decided in point 2. `status` printed
`running 1600412 machine.slice/nc-scope-gate-c78553d2.scope`, `netns`
printed `/proc/1600412/ns/net`, and `stop` ended the cage in under a
second with `status` then `stopped`.
