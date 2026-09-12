---
id: ADR-011
title: A cage may be placed on a private network, and may be given no nix daemon
status: proposed
date: 2026-09-12
status_date: 2026-09-12
summary: two enter options a dependant asked for: one veth on a named bridge at a named address, and no daemon socket
depends_on: [ADR-009, ADR-010]
supersedes: []
superseded_by: []
---

## Context

cageworks (its decision on a private network per cage) denies a role the network by not giving it one: a
per-factory bridge, one veth per cage, and two rules on the bridge that make
spend attribution by address a proof rather than a configuration. It also
wants a cage that cannot build or fetch, so that a tool reaches a cage
through the flake or not at all.

Neither is expressible with the options ADR-009 exported. Every session
shares the host's network namespace and every session gets the daemon
socket bound. ADR-009 is explicit about what happens then: the interface
changes here first, and a dependant that reaches around it has coupled
itself to what this document exists to keep private.

Two facts of systemd-nspawn settle the shape. `--network-bridge` implies
`--private-network`, creates the veth pair, puts the host side on the
bridge and names the cage side `host0`; and with `--private-network` the
cage retains `CAP_NET_ADMIN`, so a process inside can set its own address.
Nothing else sets it: nspawn brings `host0` up and assigns nothing.

## Decision

**1. `enter --network <bridge>:<address>/<prefix>`.** The caller names the
bridge and the one address the cage gets on it; nixcage owns the veth and
the capability. The bridge name is held to the kernel's fifteen characters
and an interface's alphabet, the address to one IPv4 address with its
prefix, and a placement missing either is refused where it is read. The
cage has no other interface.

**2. The session's first process is cage root long enough to set the
address, then becomes the subject.** nspawn's `--user` would switch before
`host0` exists, so when a network is asked for the switch is ours: `ip addr
add`, `ip link set host0 up`, then `setpriv` to the subject's uid and gid
with the supplementary groups cleared, and `exec` into the same command an
ordinary session runs. The command reaches that process through an
environment variable rather than argv, so that nothing in it is re-split.
A session that names no subject stays cage root, as it does today.

**3. `enter --no-nix-daemon`.** The daemon socket is not bound and
`NIX_REMOTE` is not set, so nix inside the session reaches no store and
every build or fetch fails at once. `--shell` with it is refused rather
than resolved: a devShell is realised by nix inside the session, and the
alternative is a session that fails at its first command with an error
about a socket nobody mentioned. Inside, the environment selection skips
its flake probe, which could not run, and execs the command in the base
userland; a caller that realised a toolchain elsewhere hands it in as
`--setenv NIXCAGE_PATH_PREFIX=<dir>`, put on the front of `PATH`.

**4. Both are options and both default off.** A session that asks for
neither is the session ADR-009 exported, byte for byte.

## Consequences

`modules/enter-args.sh` grows two options and one refusal; the guest script
grows one conditional block before the nspawn line and one on it. The
bridge has to exist before the session starts, and what may cross it is
the host's ruleset and not nixcage's: the rules cageworks needs are keyed
on the veth name nspawn chooses and the address the caller passed, so both
are the caller's to know. `iproute2` and `util-linux` enter the guest
script's closure by store path and not the session's profile.

A cage on a private network cannot reach anything on the host's loopback.
Services a dependant wants reachable listen on the bridge.

## Verification

`tests/unit/enter_args.bats`: a placement is parsed into its bridge and
address; one without a prefix, without a colon, or with a name that could
not be an interface is refused; no daemon is recorded when asked for and
absent otherwise; `--shell` with `--no-nix-daemon` is refused in either
order; a parse inherits neither from the last one. The guest script builds,
which runs shellcheck over the nspawn line. What the cage actually sees is
the dependant's proof, `tests/manual/isolation.sh` in cageworks.
