---
id: ADR-022
title: A cage is bounded by what the host declares, and a session may ask for something else
status: proposed
date: 2026-09-22
status_date: 2026-09-22
summary: nixcage.bounds and cages.<path>.bounds give memory and cpus to both substrates; the flag still wins
depends_on: [ADR-003, ADR-009, ADR-012, ADR-017, ADR-019]
supersedes: []
superseded_by: []
---

## Context

How much machine a cage may use is a per-session flag and nothing else.
`--memory` and `--cpus` are parsed in `modules/enter-args.sh`, become
`--property=MemoryMax=` and `--property=CPUQuota=` on an nspawn cage's scope,
and `--ram=` and `--cpus=` on a microVM's vmspawn line. The host module has no
say: `nixcage.microvm` carries `enable`, `guestModules` and `guest`, and
`nixcage.cages.<path>` carries exactly one option, `substrate`. The record a
cage keeps (ADR-017) does not carry the bounds either, so a session that asked
for more hands nothing to the next one.

Saying nothing therefore means two different things. On nspawn it means
unbounded: no `MemoryMax=`, no `CPUQuota=`, the whole host. On a microVM it
means systemd-vmspawn's own defaults, which in the systemd this host builds
against (`systemd.version` = 261.2) are 2 GiB of RAM and one vCPU:

```
src/vmspawn/vmspawn.c:144    static uint64_t arg_ram = UINT64_C(2) * U64_GB;
src/fundamental/macro.h:172  #define U64_GB (UINT64_C(1024) * U64_MB)
src/vmspawn/vmspawn.c:2723   qemu_config_section(config_file, "smp-opts", NULL,
src/vmspawn/vmspawn.c:2724                       "cpus", arg_cpus ?: "1");
```

One vCPU and 2 GiB is not a cage an agent can build in, and nothing says so:
the session boots, and the evaluation is merely slow until it is killed.

nixcage had this before the cages were native. The shared VM on macOS still
does -- `nixcage.vm.cpus` defaults to 4 and `nixcage.vm.mem` to 4096 MiB in
`modules/nixcage.nix` -- and that is the descendant of the `nixcage.vm.nix` a
1.x user wrote. The Linux host module never grew the equivalent, and ADR-019
gave the microVM substrate the flag without giving the host the declaration.

## Decision

**1. `nixcage.bounds` declares what a cage may use, and
`nixcage.cages.<path>.bounds` declares it for one cage.** One submodule with
two options, `memory` (a size in systemd's spelling) and `cpus` (a count of
whole cpus), both null by default, used in both places. This is the pairing
`substrate.default` and `cages.<path>.substrate` already have, and the host
renders it the same way, as `BOUNDS_DEFAULT` and `CAGE_BOUNDS` lines in
`/etc/nixcage/container` beside `SUBSTRATE_DEFAULT` and `CAGE_SUBSTRATES`. A
cage's path is matched whole, as a substrate declaration is: a declaration for
a directory says nothing about the directories under it, which are other cages.

Both platform modules render the default, because both run the same container
layer: `modules/host.nix` renders `BOUNDS_DEFAULT` and `CAGE_BOUNDS`, and
`modules/nixcage.nix` renders `BOUNDS_DEFAULT` alone, so a cage in the shared
VM on macOS is bounded by what the VM's configuration says rather than by the
whole VM. Per-cage bounds stay a Linux option: the macOS module has no `cages`
attribute to hang them on, because the choice it exists to make -- the
substrate -- is a Linux one, and inventing the attribute for this would put a
project path in a configuration that has never named one.

**2. One declaration, both substrates.** A bound says how much machine the cage
may use, and each substrate renders it with the strongest thing it has: nspawn
with `MemoryMax=` and `CPUQuota=` on the scope, a microVM with the guest's own
RAM and vCPU count. These are not the same guarantee -- a vCPU is a count, a
quota is a share of time -- and the declaration does not pretend otherwise. It
states the size of the machine the cage gets; what enforces it is the
substrate's business, which is the division ADR-019 already made for the
memory bound.

**3. The flag wins.** Resolution is the flag, then the cage's declaration, then
the host's default, then the substrate's own default. There is no refusal path:
a declaration is a default, not a ceiling. A caller of the exported interface
(ADR-009) already runs privileged where the cages are, so a bound it can raise
is a convenience, not a boundary, and pretending otherwise would put a security
claim on something that does not carry one. The boundary a cage has is the
substrate.

**4. The bounds are resolved every enter and never recorded.** Unlike the
substrate (ADR-019), which is fixed at the first enter because the two
substrates keep different files, a size is not a nature: a cage may be entered
small today and large tomorrow with nothing left behind. Lowering
`nixcage.bounds` and rebuilding therefore reaches every cage at its next enter,
and a one-off `--memory 8G` does not become a cage's size forever. The ADR-017
record is unchanged.

**5. Unset stays unset.** With no declaration anywhere, nothing is passed and
each substrate keeps the default it has today: unbounded on nspawn, 2 GiB and
one vCPU on a microVM. This ADR adds the declaration; it does not choose a
number on the host's behalf, because the right number is the machine's and
nixcage does not know the machine.

**6. One grammar for a size, checked in one place.** The module's option type
is the grammar `modules/enter-args.sh` already validates, `[0-9]+[KMGT]?`, and
the ADR names it here so the three validators in the path -- the Nix type, the
flag's check, and vmspawn's own `parse_size` with a base of 1024 -- cannot
drift into a value that evaluates on the host and is refused at the enter.
A `cpus` is a positive integer, as the flag's check already says.

**7. A bound never becomes a property of a microVM's scope.** ADR-019 decision
6 says why: `MemoryMax=` on that scope bounds qemu itself, so exceeding it
kills the whole guest instead of the one process, which is the opposite of
what ADR-012 promises a session. The resolution here fills the same two
variables for both substrates, which puts that mistake one refactor away, so
it is written as an invariant rather than left as a property of where the
current code happens to branch: the scope properties are the nspawn path's,
the vmspawn line is the microVM's, and nothing feeds both.

**8. `modules/bounds.sh` owns the resolution**, as `modules/substrate.sh` owns
the substrate's: the declaration's spelling, the lookup by path, and the
resolution, over inputs the suite hands it. `nixcage-container` fills
`NIXCAGE_ENTER_MEMORY` and `NIXCAGE_ENTER_CPUS` from it before the nspawn
properties and the vmspawn line are built, so both substrates are fed by the
same resolution and neither reads the declaration itself.

## Consequences

A host that declares nothing is no better off than before. The 2 GiB and one
vCPU a microVM session gets is now written down -- in this ADR, and in the
README where `--substrate microvm` is documented -- but it is still what
happens, and a user who never reads either meets it as a slow session rather
than as an error. Decision 5 is a deliberate refusal to guess, and this is
its price.

`cpus` means two things, and the ADR says which per substrate rather than
splitting the option. A host that wants a microVM's vCPUs and an nspawn cage's
quota to differ must declare the cages separately, which the per-cage option
allows.

Nothing checks a declaration against the machine it runs on. A `memory` larger
than the host's RAM is a failed boot or an overcommitted guest on a microVM,
and on nspawn a `MemoryMax=` simply never reached. nixcage does not know the
machine (decision 5), and a check that guessed would be wrong on the host that
deliberately overcommits.

The declaration is not a security boundary (decision 3), so nothing here makes
a cage safer; it makes a cage usable. A host that wants a bound a session
cannot raise has the substrate for that, and would need a ceiling this ADR
does not add.

Four surfaces gain a line each: the host module's options, the VM module's,
the rendered `/etc/nixcage/container`, and the README. The exported interface (ADR-009) is
unchanged -- `--memory` and `--cpus` already exist and still mean what they
meant -- so a dependant built on `nixcage-container enter` needs no change.

## Measurement

The defaults this ADR names are read from the systemd it runs against, not
assumed. Per gate:

```
nix eval --raw nixpkgs#systemd.version      # the version the claims are read from
grep -n 'arg_ram = ' src/vmspawn/vmspawn.c  # 2 * U64_GB, with U64_GB = 1024^3
grep -n 'arg_cpus ?: ' src/vmspawn/vmspawn.c # the "1" qemu is given when unset
```

A session's resolved bounds are checked at the line vmspawn is given, which
`enter --print-argv` prints, and at the scope's properties, which
`systemctl show` reports for an nspawn cage:

```
nixcage enter --substrate microvm --print-argv    # --ram=, --cpus=
systemctl show nixcage-<name>.scope -p MemoryMax -p CPUQuotaPerSecUSec
```
