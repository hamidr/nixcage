---
id: ADR-023
title: nixcage runs a cage on a host that declared nothing, with the guest built when a session first asks for one
status: implemented
date: 2026-09-22
status_date: 2026-09-23
summary: with no /etc/nixcage/config a session cages the current directory; uid and storage refuse, the guest builds on demand
depends_on: [ADR-003, ADR-009, ADR-019, ADR-021, ADR-022]
supersedes: []
superseded_by: []
---

## Context

nixcage cannot be tried. `nix run github:hamidr/nixcage enter` answers:

```
[nixcage] No host config at /etc/nixcage/config.
[nixcage] Import nixcage's nixosModules.host in your NixOS configuration and rebuild.
```

Two gates produce that, and both are fed only by `nixosModules.host`:
`host_read_config` reads `/etc/nixcage/config` for `WORKSPACE_ROOTS`, and
`check_workspace_root` refuses a project outside them. The reporter of issue
#1 met this immediately after meeting ADR-021's flake gate, and forked.

The gates are not the whole requirement. A session also wants
`nixcage-container` on `PATH`, `/etc/nixcage/profile`, and
`/etc/nixcage/container` for the principal uid range, the storage dataset, the
platform, the substrate declarations and, since ADR-022, the bounds. A microVM
session wants a built guest and qemu, virtiofsd and vmspawn beside it.

Most of that is not actually needed to open a cage. An ordinary session takes
its uid from `stat` on the project, not from the declared range, and
`nixcage_principal_size_at` already answers `1` when no uid store exists.
`PRINCIPAL_UID_BASE` is read by the `uid` verb alone. `read_container_config`
refuses before any of this is asked, and its own comment says what an empty
config means: no declared subjects, no dataset. So the refusal is earlier and
broader than the need.

This is also not new ground. Until 1.2.0 nixcage had no host module at all: it
wrote `.nixcage-vm/flake.nix` into the project, ran
`nix build 'path:.#nixosConfigurations.vm.config.microvm.declaredRunner'`, and
cached the result by build hash. One VM per project, qemu user-mode
networking, nothing machine-wide. Everything that now requires the host
arrived afterwards -- native containers (ADR-003), uid mapping (ADR-004,
ADR-010), the promise that a principal's number is never reissued (ADR-009),
scopes (ADR-012), veth and nftables (ADR-013, ADR-015), storage and records
(ADR-017) -- because each is a property of the machine rather than of a
project.

## Decision

**1. A host that declared nothing still runs a cage.** On Linux, when
`/etc/nixcage/config` is absent, `enter` proceeds instead of refusing, and the
cage is the directory it was run in. A host with the file keeps every
behaviour it has today: its roots gate, its substrate declarations and bounds
apply, its subjects exist. The mode is not a flag or a command; it is what
nixcage does when nobody has said anything.

**2. `$PWD` is the boundary when there is no declaration.**
`check_workspace_root` is skipped rather than satisfied with an invented root.
A caller standing in the directory is the same consent ADR-021 already accepts
for a directory that declares no flake, and inventing a root would put a
declaration in the tool's mouth.

What it does refuse is the directory nobody means: `/`, the invoking user's
home itself, `/nix` and `/nix/store`, and any directory that user does not
own. A declared root caught a mistyped `cd` and this recovers most of that
without declaring anything, since the session's uid is `stat` on the project
anyway (ADR-004) and a directory the caller does not own was never going to
be their cage.

**3. The skip is the roots gate's, not `enter`'s.** `check_workspace_root` is
where the declaration is read, so it is where its absence is answered, and
every caller of it inherits the rule: today `enter` and `rm` without a name
(ADR-021), and whatever asks next. A gate skipped in one verb and enforced in
another would let a caller make a cage it cannot remove from the directory it
made it in.

**4. State is the machine's, at `/var/lib/nixcage`.** A cage entered this way
is the same cage after the module is imported: one home, one record, one name.
Adoption keeps the work rather than abandoning it, which is the point of
trying the tool at all. The cost is that two nixcages of different versions may
write one set of records, and it is accepted -- but not silently: a record says
which nixcage wrote it and whether that session was declared, so `list --json`
can show it and a format that diverges later is a message rather than a
puzzle.

**5. `read_container_config` stops refusing, and the verbs that need a
declaration refuse instead.** Absent, the session runs with no declared
subjects, no storage dataset and no substrate declarations, which is what an
empty config already means. `nixcage-container uid <principal>` refuses naming
`nixcage.principalUidRange`, and `storage ensure` refuses naming
`nixcage.storage.dataset`: ADR-009 promises a principal's number is never
reissued, and a number invented here would be handed out against the very state
directory decision 4 shares. A dependant built on the four primitives therefore
still wants the module, and that is said rather than discovered.

For it to be said, the refusal has to be reachable: undeclared there is no
`nixcage-container` on any path, so `exec` resolves that one word to the
layer this nixcage carries and hands every other word over as it is. A
dependant then writes one line for either kind of host, which is what `exec`
exists for (ADR-009), instead of learning which kind it stands on in order to
be told it needs the other.

**6. What every session needs travels with the CLI; what only a microVM needs
is realised when one is asked for.** The closure of what `nix run` fetches is
`nixcage-container` and the container profile. The guest, qemu, virtiofsd and openssh
are realised together on the first `enter --substrate microvm` and their store
paths cached in the state directory, the way `rebuild` caches the runner on
macOS and the way 1.2.0 cached its own build under `.nixcage-vm/`. The numbers
say why: the guest is 204 derivations and 302.2 MiB of downloads (949.9 MiB
unpacked) on the flake's pinned nixpkgs, and qemu's closure is 1562 MiB
against cache.nixos.org, virtiofsd's 49 MiB. In the closure, all of it would
be paid by `nix run github:hamidr/nixcage --help`, and paid by every nspawn
session, which never runs qemu. vmspawn is part of systemd and is already on
the host a cage runs on.

**7. The machine's qemu is used when it has one, and the cost of realising
another is announced before it is spent.** `systemd-vmspawn` finds its
hypervisor itself -- `find_qemu_binary()` searches `PATH` for
`qemu-system-<arch>`, and it supports no other backend -- so a host that
already runs virtual machines needs nothing from nixcage. Only a host without
one has qemu realised for it, and undeclared that is 1562 MiB against
cache.nixos.org on top of the guest's 302.2 MiB and 204 builds, so the session
says what it is about to fetch and build and asks before doing it. A declared
host is unaffected: `nixcage.microvm.enable` already puts qemu and virtiofsd
where vmspawn looks, which is a decision its administrator made once.

**8. Store paths cross sudo as flags, not as environment.** `sudo` clears the
environment, so everything the privileged side is built from reaches it named:
the CLI runs `sudo <store>/bin/nixcage-container`, and `enter` takes
`--profile <path>` and, for a microVM, `--guest <path>` and `--microvm-path
<path>`. The last is a directory vmspawn searches, since it finds the
hypervisor and virtiofsd on its own path rather than being told where they
are. This widens the exported interface (ADR-009) by three options,
deliberately: a dependant that provisions its own layer is the same case as
nixcage running undeclared, and a preserved environment variable would make
the coupling invisible to the thing that documents the interface. A declared
host passes none of them and keeps reading `/etc/nixcage/profile` and
`MICROVM_GUEST`, with qemu and virtiofsd already on the layer's path; it also
refuses all three, because ADR-009's argument that a caller widens nothing it
could not widen itself assumes general root, and a host whose sudoers grants
`nixcage-container` alone has not given that. What a session is built from
stays the answer of whoever declared one.

**9. The guest is built from the revision the host is already running, where
the host can name one.** A NixOS machine answers with `nixos-version --json`,
which carries `nixpkgsRevision`; the guest is then evaluated against that
revision rather than against nixcage's pinned input, so glibc, systemd, bash,
coreutils and the kernel are store paths the machine already has and only
nixcage's own derivations remain to realise. This is what the declared path
does already -- `modules/host.nix` builds the guest from the host's own pkgs
(ADR-019 decision 3) -- and the undeclared path inherits the reason rather
than inventing one.

Where the host cannot name a revision, and where evaluating `modules/guest.nix`
against the named one fails, nixcage's pinned input is used instead and the
session says which it used and why. An option renamed between revisions is a
real failure mode here that the declared path meets at `nixos-rebuild` time,
with an administrator watching; undeclared it would land in the middle of an
`enter`, so it falls back rather than refuses.

**10. Undeclared, a bound is read from the machine rather than left to
vmspawn.** ADR-022 declined to choose a number because a module does not know
the machine it will be applied to. Undeclared, nixcage is standing on the
machine: it reads the cores and the memory the host has and gives a session a
share of them -- half of each -- announcing what it chose. The principle
survives, because nixcage still never guesses on a host's behalf in a module,
and a flag or a declaration still outranks this. Without it the first microVM
anybody tries has systemd-vmspawn's 2 GiB and one vCPU, which is the cage
ADR-022 exists to stop handing out.

**11. Undeclared, a session's git identity is read, never bound.** The module
renders `/etc/nixcage/gitconfig` from `nixcage.git.*`; undeclared, nixcage
asks the host's own git for `user.name` and `user.email` and renders the same
minimal file. The invoking user's `~/.gitconfig` is never bound in: it carries
`credential.helper` and signing configuration, which is what ADR-008 keeps out
of a cage. Signing still goes through the forwarded agent, as it does on a
declared host.

## Assumptions

Written down because an undeclared host has told nixcage nothing, so every one
of these is something the tool is taking on faith rather than reading:

- Linux with systemd 261 or newer, for `systemd-vmspawn`; `systemd-nspawn`
  comes with systemd either way. NixOS is not assumed: the nspawn path wants a
  systemd host with Nix on it and nothing more, and decision 9 asks the host
  for a revision rather than requiring that it have one.
- `/dev/kvm` present and usable. Without it a microVM is emulation, which is
  slow enough to be useless, and `nixcage_microvm_refusal` already says so.
- The invoking user can `sudo`. Every session is privileged; this ADR removes
  a declaration, not the root requirement.
- Nix with flakes, and reachable substituters on first use.
- The host's architecture is the one the guest is built for, `x86_64-linux` or
  `aarch64-linux`.
- `systemd-machined` answers, since `machinectl show` is where `exec` reads a
  microVM cage's key and address. What resolves that address is not assumed:
  systemd ships the ssh snippet giving `vsock/*` its `ProxyCommand` and
  nixcage names it on the command line rather than relying on the
  distribution's `ssh_config` including it.
- `/var/lib/nixcage` is root-writable and stable, and no second nixcage of a
  different version is writing records there at the same time (decision 4).
- The project directory belongs to the invoking user, since the session's uid
  is `stat` on it (ADR-004).
- Nothing undeclared wants a bridge, a veth or an nftables rule: a bridge is
  declared by a host (ADR-018), and there is no host here to declare one.
- The guest is rebuilt per nixpkgs revision, so its cost recurs on a flake
  bump rather than once per machine.

## Consequences

Two supported ways to run nixcage, so every option added from here has to
answer what it means undeclared. Two of today's options are not gaps at all:
`cages.<path>` addresses one cage among many and undeclared there is exactly
one, the current directory; and a bridge is a network a host built (ADR-018),
which an undeclared host has not. `git.*` and `bounds` are answered by
decisions 10 and 11. What is left with no undeclared equivalent is `secretEnv`
and `principalSubjects`: an undeclared session has no secrets, because the
host environment is never read, and no declared subjects. `status` says so,
rather than leaving the difference to be inferred.

To keep that question cheap to answer as options are added, the declaration is
one thing the code asks rather than a spelling scattered through it: a single
reader with two implementations, the rendered file and the undeclared
defaults. A new option then has one place to state its undeclared value, and
the suite can enumerate them. Retrofitting this after `[ -f
/etc/nixcage/... ]` has spread through the script costs far more than writing
it this way now.

Secrets need nothing new: `write_secret_env` already returns early when
`/etc/nixcage/secret-env` is absent, so an undeclared session simply has none.
Verified in `modules/container.nix`, not assumed.

How much decision 9 saves is reasoned, not measured: on this macOS host no
Linux path is present, so the 302.2 MiB above is the cost of sharing nothing.
A NixOS host on the same revision as the guest shares most of a minimal
system's closure and should be left with nixcage's own derivations, but that
number wants measuring on such a host before it is quoted.

What the guest's 302.2 MiB is made of has not been measured -- the kernel,
systemd, and whatever of the userland a session without a nix daemon still
needs. It is treated here as a fixed number, and it may not be one; trimming
it is worth a measurement before the mode is called cheap.

The guest is built rather than downloaded on a machine with only
cache.nixos.org, because 204 of its derivations are nixcage's own. How long
that takes has not been measured, and the count is misleading on its own:
those derivations are unit files, `/etc` sets and a toplevel, not compilers,
so the wait may be a minute rather than an hour. Measure it before quoting
either. Publishing
them to a binary cache on release turns the first microVM session from a
compile into a fetch; until that exists, decision 6's "realised on demand"
means "compiled on demand" for the first caller.

`nix run` re-evaluates the flake on every invocation, which is the wrong shape
for daily use. The README points at `nix profile install
github:hamidr/nixcage` for that, which is also the honest upgrade path from
trying nixcage to keeping it.

An undeclared microVM session is bounded by what decision 10 reads off the
machine, which is a share rather than a measurement of what the session needs;
`--memory` and `--cpus` outrank it. The README says this where it says what
the mode is.

ADR-003 put the host in charge deliberately, and this softens that: a machine
can now hold cages nobody declared. The boundary that remains is root -- every
session still goes through `sudo nixcage-container` -- and `$PWD`, which is
weaker than a declared workspace root and is the price of the mode.

Nothing changes for a declared host. The gates it renders still gate, and the
suite's existing expectations for `/etc/nixcage/config` stay as they are;
what is added is the case where the file is not there.

## Measurement

The costs decision 6 turns on are read rather than assumed:

```
nix build --dry-run --impure --expr '<the guest toplevel for x86_64-linux>'
# these 204 derivations will be built:
# these 301 paths will be fetched (302.2 MiB download, 949.9 MiB unpacked)

nix path-info --store https://cache.nixos.org -S nixpkgs#legacyPackages.x86_64-linux.qemu_kvm
# 1562 MiB
nix path-info --store https://cache.nixos.org -S nixpkgs#legacyPackages.x86_64-linux.virtiofsd
# 49 MiB
```

A slimmer qemu is not a saving unless nixcage caches it: an override of
`qemu_kvm` is absent from cache.nixos.org, so asking for one makes the caller
compile qemu rather than fetch it. Measured by the same command against the
override, which answers `path ... is not valid`.

The mode itself is checked by what a session is given rather than by what it
prints, with no host config in place:

```
time nix build <the guest toplevel>             # open: what 204 own derivations cost
nixos-version --json                            # the revision decision 9 builds against
nixcage enter --print-argv                      # the nspawn line, no /etc/nixcage
nixcage enter --substrate microvm --print-argv  # the vmspawn line, guest path from the cache
nixcage-container uid worker                    # refuses, naming nixcage.principalUidRange
```
