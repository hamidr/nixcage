---
id: PRD-002
title: A flake's closure reaches a Kubernetes pod as a volume, not as an image
status: proposed
date: 2026-09-17
status_date: 2026-09-17
summary: one flake root runs in a cage locally and, via nixkube, in a pod; nixcage pushes it and emits the fragment
depends_on: [PRD-001, ADR-009, ADR-011, ADR-014]
supersedes: []
superseded_by: []
phases_total: 3
phases_done: 0
---

## Problem

A team that already builds with Nix and deploys to Kubernetes throws away
most of what Nix gave them at the last step. `nix build` produces a closure:
a graph of store paths, each named by the hash of everything that went into
it, each reachable from the root by a recorded edge. Then a Dockerfile,
`dockerTools` or `nix2container` flattens that graph into layers of tarballs,
pushes them to a registry, and every node pulls the tarballs. What runs is a
copy of what was built, with the graph stripped off.

What is lost at that step:

- **The graph.** An image is files. Which package brought which library,
  and why, is not a question an image can answer; the team re-derives it
  with a scanner that guesses from file names and version strings. The
  closure knew. `nix path-info -r`, `nix derivation show` and `nix why-depends`
  answer on the machine that built it and cannot answer inside the pod.
- **The identity.** A store path's name is a hash of its inputs, so "what
  runs" and "what was built" are the same object, checkable by name. An
  image tag is a mutable pointer, and an image digest names bytes, not
  provenance. Compliance work that could be `nix path-info --json` against
  a signed cache becomes an SBOM tool reading tarballs after the fact.
- **The bound.** A closure contains what the program needs and nothing
  else. No base image, no package manager, no `/bin/sh` unless declared.
  An image starts from a distribution and subtracts; what remains is
  attack surface nobody chose. When a CVE lands in a library, the closure
  says which roots depend on it by edge, not by grep.
- **The sharing.** Store paths dedupe by hash across every closure on a
  node. Layers dedupe only when two images happen to produce byte-identical
  tarballs, which Nix outputs in different images do not. Two services that
  share glibc, openssl and a language runtime ship them twice and store them
  twice.
- **The step itself.** The flake already says what the program needs. The
  image build is a second description that drifts: a base image tag, a
  `COPY` of a store path, a `nix copy` into a scratch layer. It breaks at
  deploy, not at `nix build`.

The people who hurt: the operator paying for a registry and node disk full
of copies of the same few hundred store paths; the security or compliance
owner reconstructing with a scanner what the build already knew; the
developer maintaining a Dockerfile beside a flake that says the same thing;
whoever debugs a pod and finds `/nix/store` holds one path and no way to
ask what it is.

nixcage already keeps the graph intact for one machine: a cage without the
daemon sees exactly the closure of its roots and nothing else of the store
(ADR-014). A pod is a cage on a node it does not own. This document asks how
the same promise is kept when the substrate is a cluster: the closure
arrives as a closure, signed, deduplicated, bounded and queryable, and the
image step disappears.

## What nixcage is, in this setting

Not a container runtime and not an image format. It is the piece that
carries a Nix closure from the machine that built it into the pod that runs
it without flattening it on the way. Everything it promises, Nix already
promised about the closure; nixcage's job is to not lose any of it:

- what runs is what was built, by hash, signed by the cache key the node
  trusts;
- the pod holds exactly the closure of its declared roots, so the attack
  surface is what the flake chose and nothing inherited;
- every store path on a node exists once, whatever runs there;
- the graph is queryable from the roots the pod declares, against the cache
  or the node, by anyone with `nix`; inside the pod too, since the volume
  carries a store database, given the root's closure includes `nix`;
- the same root, unchanged, runs in a cage on the developer's machine
  (`enter --store-root`, ADR-014) and in a pod on the cluster. One closure,
  two substrates, no image in between.

## Prior art, and what this document decided because of it

[nixkube](https://github.com/Lillecarl/nixkube) (MIT, formerly nix-csi) is a
CSI driver and NRI plugin that mounts a Nix closure into a pod. Per volume it
hardlinks the closure into a volume root with its own store database and
gcroots, bind-mounts that root once, verifies paths before mounting, keys
store paths by system for multi-architecture clusters, reports Kubernetes
events, exports metrics, and ships its own Nix in a DaemonSet so any node
qualifies. It also builds `flakeRef` and `nixExpr` on the cluster when asked.

An earlier draft of this document specified a nixcage-owned CSI agent. Set
beside nixkube it was a subset with two fewer capabilities (in-pod store
database, multi-architecture) and one unsolved problem (a bind mount per
store path, tens of thousands per node) that nixkube's hardlink farm does not
have. Building it would have rebuilt a smaller nixkube. Decision, 2026-09-17:

- nixcage does not own a node agent. The volume a pod declares names
  nixkube's driver.
- What nixcage owns is the two ends nixkube leaves to the user: turning a
  flake root into the volume a pod declares, and getting that root's closure
  to a cache the nodes trust. Plus the thing only nixcage has: the same root
  entering a cage locally.
- What nixkube lacks and this document needs goes upstream, not into this
  repository: a policy that accepts `storePath` only and never builds on a
  node. A NixOS-native node component was considered and dropped
  (Decisions, D4): nixkube's DaemonSet runs on a NixOS node like on any
  other, and nothing in the metrics needs more.

## Target users

- **Primary:** an operator running Kubernetes with nixkube deployed, whose
  team builds with Nix and has a binary cache the nodes trust.
- **Secondary:** a developer on that team who wants what `nixcage enter`
  runs locally to be, root for root, what runs on the cluster.
Not a target: a team without nixkube. This document does not deploy it;
nixkube's own manifests do.

## Success metrics

- One flake root, two substrates, one closure: the pod declaring `<root>`
  holds exactly `nix path-info -r <root>`, and `nixcage enter --no-nix-daemon
  --store-root <root>` locally holds that same set plus only what ADR-014
  declares as the base userland (profile, certificate bundle). Measured:
  `ls /nix/store` in the pod equals the closure; in the cage it equals the
  closure union the base, nothing more. The local half rests on ADR-011
  (proposed) and ADR-014 (implementing); phase 1 needs neither, this metric
  needs both.
- Deploying a change is `nix build` plus one upload. No image build, no
  registry push, no `Dockerfile` in the repository.
- nixkube's store on a node (`hostMountPath`, its own, beside the node's
  `/nix/store`) holds each store path once, however many pods on that node
  use it. Measured, with its GC paused: growth after N pods of M services
  equals the union of closures, not the sum. Paths the node's own system
  closure also has are stored twice, once per store; that is nixkube's
  layout and not counted here.
- Given a pod's declared root and the cache, `nix path-info -r --json
  --store <cache>` lists its full dependency set with hashes; no scanner, no
  access to the pod. A CVE in one path is traced to every deployed root that
  depends on it in two steps: collect the roots the fleet declares
  (`kubectl get pods -A -o json`, the system-keyed `volumeAttributes`), then
  `nix why-depends` per root against the cache. No image pull.
- A pod whose root is not in the cache does not start and its events say
  which path was missing (nixkube's behaviour; this document relies on it and
  the probe checks it).
- The nspawn path, the four exported primitives (ADR-009) and cageworks are
  unchanged. Measured: their suites pass with no edits.

## Scope

In:

- A pure Nix function, `nixcage.lib.kubernetes.container`, that turns a
  flake root into the container fragment a pod declares for nixkube: volume,
  mount, and when derivable, command and `PATH`. The flake is the source of
  truth and Nix-side tooling (kubenix, plain `builtins.toJSON`) composes it
  without a shell.
- A CLI verb, `nixcage push`, that builds an installable, signs and copies
  its closure to the configured cache, and prints that same fragment.
- One contribution to nixkube, tracked here as a phase and delivered there:
  a `storePath`-only policy. Plus one issue asking for the interface the
  fragment relies on to be declared public.
- One probe proving the round trip against a real nixkube.

Out, explicitly:

- **A nixcage-owned node agent, CSI or NRI.** nixkube's. See the decision
  above.
- **Deploying nixkube.** Its manifests, its cache (`pynixd`) if used, its
  namespace and RBAC are its own. On a NixOS node too: no NixOS module for
  its node component here or upstream from here (D4).
- **A container image.** The fragment is image-agnostic (D1, D2); nixcage
  publishes none and recommends none beyond an example.
- **Generating a Pod, Deployment, Job or any workload object.** The caller
  owns replicas, ports, probes, resources, env, service accounts and the
  image the container nominally runs. nixcage emits what Kubernetes cannot
  know: which root, and where it mounts. A whole-Pod generator waits for
  three callers writing the same skeleton.
- **Applying anything to a cluster.** No kubeconfig is read.
- **Building on the cluster.** nixkube offers `flakeRef` and `nixExpr`; the
  fragment never emits them. What runs was built and signed before it was
  pushed, or it does not run.
- **A source tree in the pod.** Deploy has no `/workspace`.
- **Secrets, networking, storage for the pod.** Kubernetes-native, the
  caller's.
- **Turning a Dockerfile or an image into a flake.** Considered and dropped
  2026-09-17: an image has no graph to recover, and a Dockerfile translator
  is a different product for a different user.
- **A formal model.** No protocol is designed here; nixkube owns the one
  that would have needed it.

## Requirements

Each is a behaviour a test can watch, not a mechanism.

**Nix function `nixcage.lib.kubernetes.container`**

- R1. A caller can pass a derivation or a store path string as the root and
  get an attrset holding the volume (`csi.driver = "nixkube"`, the root
  keyed by its system) and the mount (`mountPath = "/nix"`, `subPath =
  "nix"`, as nixkube requires), ready for `builtins.toJSON`.
- R2. A caller with roots for more than one system passes one per system
  and gets one volume carrying all of them; a pod then runs on whichever
  architecture schedules it. The system of a derivation root is read from
  it; a string root carries none, so a caller passing strings names the
  system beside each.
- R3. A caller with several roots for one system is refused with a message
  naming `buildEnv`: nixkube takes one path per system, and the function
  does not silently pick.
- R4. A root that is not a store path is refused at evaluation time with a
  message naming it.
- R5. For a derivation root with `meta.mainProgram`, the fragment also
  carries `command = [ "/nix/var/result/bin/<mainProgram>" ]` and `env =
  { PATH = "/nix/var/result/bin"; }`. `env` is an attrset, not the list
  Kubernetes takes, so a caller merges with `//` and converts once
  (`lib.mapAttrsToList (name: value: { inherit name value; })`); a list
  would only concatenate, and duplicate `PATH` entries resolve by position.
  Both fields are offered, not imposed. A string root, or a derivation
  without `mainProgram`, gets neither and no error. With roots for several
  systems, `mainProgram` must agree across them or the function refuses,
  naming the two values; a pod has one `command`.
- R6. The function has no dependency on the CLI or on nixkube's repository:
  a flake that never runs `nixcage` produces the same fragment.

**CLI `nixcage push`**

- R7. A user can name one installable per system and get each closure
  signed, copied to the configured cache, and one fragment carrying all of
  them on stdout, in one command. How a foreign system gets built (cross,
  a remote builder, or already substitutable) is the user's Nix
  configuration, as for `nix build`; `push` names no builder. Two
  installables for one system are refused as R3 refuses them.
- R8. The cache URL and the signing key file are configured once and
  overridable per invocation (`--cache`, `--secret-key-file`). Both are
  CLI-side: the key never leaves the machine `push` runs on, so on macOS it
  is not a VM module option.
- R9. With no cache configured the command fails before building and says
  where to configure one. With no key configured it fails the same way,
  before building; `--unsigned` is the explicit opt-out for a cache that
  does not check signatures, and it is a flag, never a config default, so
  an unsigned push is one somebody typed.
- R10. The CLI prints exactly what the Nix function returns for the same
  root. There is one definition of the fragment.
- R11. The same root the CLI pushed is accepted by `enter --store-root`
  unchanged. Nothing about pushing changes the root's spelling.

**Upstream, nixkube**

- R12. An operator can configure a node to accept `storePath` volumes only,
  so no pod can cause a build on a node.

**Probe**

- R13. On a NixOS node with nixkube's DaemonSet, a root pushed by
  `nixcage push` and declared with the emitted fragment, in a pod whose
  nominal image ships no `/nix`, starts and runs it, and `ls /nix/store`
  inside that pod equals the root's closure.

## Phases

1. **The fragment.** `nixcage.lib.kubernetes.container`, `nixcage push`,
   cache URL and key file in CLI-side config. Verifiable with the existing
   bats pattern (stubbed `nix`) and evaluation in
   `tests/command/modules.bats`. A caller can already paste the output into
   a cluster that has nixkube.
2. **Upstream.** One pull request to nixkube: `storePath`-only policy
   (R12). One issue: declare `driver`, the system-keyed attribute,
   `subPath = "nix"` and `/nix/var/result` a public interface with a
   version. Done when the PR is merged or declined and this document
   records the outcome; the issue's answer is recorded whichever way it
   goes. Not blocking phase 3.
3. **The probe.** One NixOS test: a k3s node with nixkube's DaemonSet at a
   pinned rev, a local cache, `push` of a hello closure, a Pod with
   `registry.k8s.io/pause` as nominal image that runs it, closure equality
   checked. Gated and slow, like the `templates/config` probe.

## Decisions taken on the open questions

Resolved 2026-09-17, one at a time; the alternatives are kept so a later
reader can see what was not chosen.

- **D1. Command.** The function offers `command` from `meta.mainProgram`
  via `/nix/var/result/bin` and `PATH` pointing there, `env` as an attrset
  so it merges; a caller may ignore both (R5). Rejected: emitting nothing (two places would name the
  package); emitting only one of the two (the pair is what makes any image
  work).
- **D2. Nominal image.** No recommendation beyond a requirement (the image
  must not ship `/nix`) and an example (`registry.k8s.io/pause`, already on
  every node). Rejected: recommending nixkube's scratch image (a registry
  dependency per pod start); publishing our own (a registry, which this
  document exists to remove).
- **D3. Cache authentication.** `push` takes a cache URL and a signing key
  file, CLI-side, and nothing else; reading credentials, netrc, S3 and ssh
  are `nix copy`'s own. The read side is nixkube's `nixConfig` and not
  ours. No key is an error, `--unsigned` the typed opt-out (R9). Rejected:
  URL only (unsigned paths are what a strict node refuses); warn-and-copy
  (contradicts "what runs was signed"); mirroring `nix copy`'s flag set.
- **D4. Upstream scope.** Only the `storePath`-only policy goes upstream. A
  NixOS-native node component is dropped, not deferred: nixkube's DaemonSet
  works on a NixOS node and no metric needs more. Rejected: issues-then-PRs
  for both (waits on a maintainer for a nicety); forking the node component
  here (an agent by another name).
- **D5. Names.** `nixcage push` and `nixcage.lib.kubernetes.container`.
  `push` is what `nix copy` is to a user who knows git and docker. The
  namespace leaves room for a second Kubernetes function without a rename;
  `container` says what shape comes back. Rejected: `ship`, `export`,
  `publish`; `lib.volume` (returns more than a volume), `lib.pod`
  (returns less than one), `lib.fragment` (says nothing of the domain).
- **D6. Pinning nixkube's interface.** The probe pins a nixkube rev; the
  fragment carries no version. An upstream issue asks for the interface to
  be declared public and versioned (phase 2). Rejected until a second
  version exists: an interface-version annotation on the fragment, a
  `nixkubeVersion` argument to the function.

## Open questions

- **Q1. Where CLI-side config lives.** Today the CLI reads
  `/etc/nixcage/config` on Linux (rendered by the host module) and the VM
  build cache on macOS. Cache URL fits the host module on Linux; the key
  file path and, on macOS, both values are laptop facts with no home yet.
  Candidates: a `[push]` block in a `${XDG_CONFIG_HOME}/nixcage/push` file
  the CLI reads on both platforms; or host-module option on Linux plus
  flags-only on macOS. Deciding in phase 1 when the first test needs one.

## Consequences

The repository gains no Go and no agent. What it gains is one Nix function,
one CLI verb, one piece of CLI-side configuration, and a probe with a new
flake input.
The nspawn side is untouched except that ADR-014's `--store-root` acquires a
second reason to exist: it is the local half of the promise this document
makes.

The platform seam (`detect_os`) does not grow a third branch. A cluster is
not a place `enter` reaches; it is a place `push` sends to.

A dependency on nixkube's interface is taken knowingly. It is a small
surface (a driver name, an attribute key, a mount rule), read from their
tree and checked by the probe. If it moves, the fragment moves with it and
callers regenerate; nothing on a cluster breaks retroactively.
