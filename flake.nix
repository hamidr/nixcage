{
  description = "One shared NixOS microVM with per-project containers for AI coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          self',
          pkgs,
          lib,
          ...
        }:
        let
          cli = import ./package.nix { inherit pkgs; };
          inherit (cli) container;
        in
        {
          ## The CLI, plus the pieces a session is built from where nothing
          ## was declared: exported by name so a release can build them and
          ## the suite can ask for them.
          packages =
            lib.optionalAttrs (container ? script) {
              container = container.script;
              containerProfile = container.profile;
              ## What a microVM session needs and an nspawn session does not,
              ## which is why they are outputs of their own rather than part
              ## of what the CLI carries: realised the first time a session
              ## asks for one (ADR-023 decision 6). The guest is built here
              ## from nixcage's pinned nixpkgs; a session on a host that names
              ## a revision overrides that input to the host's own
              ## (decision 9).
              guest = (pkgs.nixos [ ./modules/guest.nix ]).config.system.build.toplevel;
              qemu = pkgs.qemu_kvm;
              virtiofsd = pkgs.virtiofsd;
              ## exec on a microVM cage and the agent forward are both ssh
              ## over vsock, and an undeclared host has no openssh where the
              ## session looks for one.
              openssh = pkgs.openssh;
            }
            // {
              default = cli;
            };

          ## The one test that boots what every other test only describes: a
          ## NixOS machine running the host module, a second running nothing
          ## but the CLI, and a cage entered on each for real. Linux only,
          ## because a NixOS test is a Linux virtual machine.
          checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            ## A bridge-placed cage is a veth nspawn is handed, and nspawn
            ## refuses one udev has not finished with: on a NixOS host 2
            ## enters in 12 failed so before nixcage_veth_make waited. Many
            ## enters, one after another and side by side, every one of them
            ## succeeding, under names longer than an interface's.
            bridged = pkgs.testers.runNixOSTest {
              name = "nixcage-bridged-enters";

              nodes.host = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
                nixcage.bridges.nc0 = {
                  address = "10.66.0.1";
                  prefix = 24;
                };
                ## What the host the race was seen on runs: something that
                ## takes an interest in every new link.
                networking.networkmanager.enable = true;
                environment.systemPackages = [
                  self'.packages.default
                  pkgs.socat
                ];
                virtualisation.memorySize = 2048;
              };

              testScript = ''
                start_all()
                host.wait_for_unit("multi-user.target")

                # ADR-018: the bridge is the host's before any cage is on it.
                with subtest("the bridge has its address before any cage, and a service there answers"):
                    host.succeed("ip -4 addr show nc0 | grep -q 'inet 10.66.0.1/24'")
                    host.succeed(
                        "socat TCP-LISTEN:7000,bind=10.66.0.1,fork SYSTEM:'echo up' >/dev/null 2>&1 &"
                    )
                    host.wait_until_succeeds("socat -T2 - TCP:10.66.0.1:7000 </dev/null | grep -qx up", timeout=10)

                def enter(i):
                    name = f"a-bridged-cage-named-{i:02d}"
                    return (
                        f"mkdir -p /srv/p{i} && nixcage exec -- nixcage-container enter"
                        f" --no-agent --network nc0:10.66.0.{10 + i}/24 {name} /srv/p{i} true"
                    )

                with subtest("enters one after another all start"):
                    for i in range(20):
                        host.succeed(enter(i))

                with subtest("enters side by side all start"):
                    # Each writes its own status: a record is written before
                    # nspawn runs, so what lists is no evidence of a start.
                    jobs = " ".join(
                        f"( {enter(20 + i)}; echo $? >/tmp/rc-{i} ) &" for i in range(8)
                    )
                    host.succeed(f"rm -f /tmp/rc-*; {jobs} wait")
                    out = host.succeed("cat /tmp/rc-0 /tmp/rc-1 /tmp/rc-2 /tmp/rc-3 /tmp/rc-4 /tmp/rc-5 /tmp/rc-6 /tmp/rc-7")
                    assert out.split() == ["0"] * 8, out

                with subtest("a placed cage holds the address it was given"):
                    host.succeed(
                        "nixcage exec -- nixcage-container enter --no-agent"
                        + " --network nc0:10.66.0.99/24 a-bridged-cage-named-99 /srv/p0"
                        + " bash -c 'grep -q 10.66.0.99 /proc/net/fib_trie'"
                    )
              '';
            };

            ## The layer an undeclared host runs is built from this flake's
            ## own nixpkgs, and a microvm session refuses a vmspawn before
            ## 261 (microvm-session.sh). A pin behind that makes every
            ## undeclared microvm session a refusal, so the pin is checked.
            ## What a machine gets through the overlay is the CLI too, and
            ## has to start: 5.1.0's overlay built one that could not.
            overlayCli =
              pkgs.runCommand "nixcage-overlay-cli" { } ''
                ${(pkgs.extend inputs.self.overlays.default).nixcage}/bin/nixcage version >$out
              '';
            carriedVmspawn =
              assert lib.assertMsg (lib.versionAtLeast pkgs.systemd.version "261")
                "the carried layer's systemd ${pkgs.systemd.version} has a vmspawn older than 261";
              pkgs.runCommand "nixcage-carried-vmspawn" { } "touch $out";

            ## The sequence a dependant performs, against a real machine: a
            ## uid for a principal, storage given to that uid, a session that
            ## runs as it, and a way back to the host. The parts have tests of
            ## their own; what is asserted here is the seam between them and
            ## the promises that only real state can show (ADR-009).
            primitives = pkgs.testers.runNixOSTest {
              name = "nixcage-exports-four-primitives";

              nodes.host = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
                nixcage.principalUidRange = {
                  base = 700000;
                  size = 64;
                };
                nixcage.principalSubjects = [ "agent" ];
                ## A person whose agent a session is handed.
                users.users.alice.isNormalUser = true;
                environment.systemPackages = [ self'.packages.default ];
                virtualisation.memorySize = 2048;
              };

              testScript = ''
                start_all()
                host.wait_for_unit("multi-user.target")

                def container(*words):
                    return host.succeed(
                        "nixcage exec -- nixcage-container " + " ".join(words)
                    ).strip()

                with subtest("one name always answers with one number"):
                    first = container("uid", "worker")
                    again = container("uid", "worker")
                    assert first == again, (first, again)
                    assert int(first) >= 700000, first

                with subtest("a second principal is a block of its own"):
                    other = container("uid", "builder")
                    assert other != first, (other, first)
                    assert abs(int(other) - int(first)) >= 2, (other, first)

                with subtest("a subject of a principal is that principal's own number"):
                    subject = container("uid", "worker", "agent")
                    assert int(subject) == int(first) + 1, (subject, first)

                with subtest("allocation only ever moves forward"):
                    # Not the whole promise: that a number is never reissued
                    # cannot be shown without losing a principal and asking
                    # again. What is shown here is the property the promise
                    # rests on, that a new name never lands under an old one.
                    third = container("uid", "later")
                    assert int(third) > max(int(first), int(other)), third

                with subtest("a path given to a uid belongs to it"):
                    path = container(
                        "storage", "ensure", "/var/lib/nixcage/work/worker", first
                    )
                    assert path == "/var/lib/nixcage/work/worker", path
                    owner = host.succeed("stat -c %u " + path).strip()
                    assert owner == first, (owner, first)

                with subtest("a path outside what nixcage owns is refused"):
                    host.fail(
                        "nixcage exec -- nixcage-container storage ensure "
                        "/etc/nixcage-elsewhere " + first
                    )

                with subtest("a session runs as the uid it was given"):
                    # Owned by that uid, as a dependant's worktree is.
                    host.succeed("mkdir -p /srv/proj && chown " + first + " /srv/proj")
                    out = host.succeed(
                        "nixcage exec -- nixcage-container enter --uid " + first
                        + " --setenv K=V --bind-ro /srv:/srv-ro"
                        + " cage /srv/proj sh -c 'echo $K; test -e /srv-ro/proj;"
                        + " touch /workspace/written'"
                    )
                    assert "V" in out, out
                    # Root inside is subject 0 of the cage's block (ADR-010),
                    # so the uid it was given shows on the host, not in id.
                    owner = host.succeed("stat -c %u /srv/proj/written").strip()
                    assert owner == first, (owner, first)

                with subtest("a session reaches the caller's agent without taking it"):
                    host.succeed("runuser -u alice -- ssh-agent -a /tmp/alice-agent.sock")
                    before = host.succeed("stat -c %u /tmp/alice-agent.sock").strip()
                    out = host.succeed(
                        "nixcage exec -- nixcage-container enter --uid " + first
                        + " --auth-sock /tmp/alice-agent.sock cage /srv/proj"
                        + " sh -c 'ssh-add -l; echo rc=$?'"
                    )
                    # 1 is an agent with no keys; 2 is no agent reached.
                    assert "rc=1" in out, out
                    after = host.succeed("stat -c %u /tmp/alice-agent.sock").strip()
                    assert after == before, (after, before)

                with subtest("what the session was given is in its record"):
                    record = host.succeed(
                        "cat /var/lib/nixcage/containers/cage/placement"
                    )
                    assert '"uid":' + first in record, record

                with subtest("exec reaches the machine the cages are on"):
                    assert "cage" in host.succeed(
                        "nixcage exec -- nixcage-container list"
                    )
              '';
            };

            cage = pkgs.testers.runNixOSTest {
              name = "nixcage-enters-a-cage";

              nodes.declared = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
                ## What this host says every session of that cage has,
                ## whatever its caller asked for.
                nixcage.cages."/srv/proj".binds = [ "/srv/shared:/shared:ro" ];
                ## Declared here because the uid verb refuses without it, and
                ## that refusal is what the bare node is for.
                nixcage.principalUidRange = {
                  base = 700000;
                  size = 64;
                };
                environment.systemPackages = [ self'.packages.default ];
                virtualisation.memorySize = 2048;
              };

              ## No module, nothing under /etc/nixcage: the cage is the
              ## directory the caller stands in, and what a session is built
              ## from is what the CLI carries (ADR-023).
              nodes.bare = {
                environment.systemPackages = [ self'.packages.default ];
                virtualisation.memorySize = 2048;
              };

              testScript = ''
                start_all()
                declared.wait_for_unit("multi-user.target")
                bare.wait_for_unit("multi-user.target")

                with subtest("a declared host enters the cage of a project"):
                    # The declared bind's source exists before any enter: a
                    # missing one fails every session of the cage.
                    declared.succeed("mkdir -p /srv/proj /srv/shared && touch /srv/shared/marker")
                    declared.succeed("cd /srv/proj && nixcage enter -- true")
                    record = declared.succeed(
                        "cat /var/lib/nixcage/containers/*/placement"
                    )
                    assert '"declared":true' in record, record

                with subtest("a cage carries the binds its host declared"):
                    declared.succeed(
                        "cd /srv/proj && nixcage enter -- test -e /shared/marker"
                    )
                    declared.fail(
                        "cd /srv/proj && nixcage enter -- touch /shared/written"
                    )
                    record = declared.succeed(
                        "cat /var/lib/nixcage/containers/*/placement"
                    )
                    assert "declaredBinds" in record, record

                with subtest("a session asking for the same destination is refused"):
                    declared.fail(
                        "cd /srv/proj && nixcage enter --bind /tmp:/shared -- true"
                    )

                with subtest("a project outside every root is refused"):
                    declared.succeed("mkdir -p /elsewhere/proj")
                    declared.fail("cd /elsewhere/proj && nixcage enter -- true")

                with subtest("what the session was given reaches it"):
                    out = declared.succeed(
                        "cd /srv/proj && nixcage enter --setenv K=V -- sh -c 'echo $K'"
                    )
                    assert "V" in out, out

                with subtest("the project is the session's workspace"):
                    declared.succeed("touch /srv/proj/marker")
                    declared.succeed(
                        "cd /srv/proj && nixcage enter -- test -e /workspace/marker"
                    )

                with subtest("a host that declared nothing enters the directory it is in"):
                    bare.succeed("mkdir -p /root/work")
                    bare.succeed("cd /root/work && nixcage enter -- true")
                    record = bare.succeed("cat /var/lib/nixcage/containers/*/placement")
                    assert '"declared":false' in record, record
                    assert '"writer":"/nix/store/' in record, record

                with subtest("the directories nobody means are refused"):
                    bare.fail("cd / && nixcage enter -- true")
                    bare.fail("cd /root && nixcage enter -- true")
                    bare.fail("cd /nix/store && nixcage enter -- true")

                with subtest("a verb only a declaration can answer refuses, naming it"):
                    out = bare.fail(
                        "nixcage exec -- nixcage-container uid worker 2>&1"
                    )
                    assert "nixcage.principalUidRange" in out, out
                    uid = declared.succeed(
                        "nixcage exec -- nixcage-container uid worker"
                    ).strip()
                    assert uid.isdigit(), uid

                with subtest("a declaration an older nixcage rendered is still read"):
                    # What a partial upgrade leaves: a CLI newer than the
                    # module it stands on. Last, because it takes the
                    # declaration away.
                    declared.succeed("rm /etc/nixcage/declaration /etc/nixcage/config")
                    declared.succeed(
                        "printf 'WORKSPACE_ROOTS=/srv\\n' > /etc/nixcage/config"
                    )
                    out = declared.succeed(
                        "cd /srv/proj && nixcage enter -- true 2>&1"
                    )
                    assert "older nixcage" in out, out
                    declared.fail("cd /elsewhere/proj && nixcage enter -- true")
              '';
            };
          };

          ## Checks that boot a machine inside the test VM, so they want the
          ## runner to nest KVM twice, which CI's runners do not: kept out of
          ## `checks` and run on a host that nests, with
          ## `nix build .#hostChecks.microvm`. The microVM path is otherwise
          ## covered only by unit tests of its parts.
          legacyPackages.hostChecks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            microvm = pkgs.testers.runNixOSTest {
              name = "nixcage-microvm-session";

              nodes.host = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
                nixcage.microvm.enable = true;
                ## A person whose agent a session is handed.
                users.users.alice.isNormalUser = true;
                environment.systemPackages = [
                  self'.packages.default
                  pkgs.hello
                ];
                virtualisation.memorySize = 4096;
                virtualisation.cores = 2;
              };

              testScript = ''
                start_all()
                host.wait_for_unit("multi-user.target")
                host.succeed("mkdir -p /srv/proj")
                # The guest may boot the very kernel the host runs; its own
                # boot is what shows it is a kernel of its own.
                boot = "cat /proc/sys/kernel/random/boot_id"
                host_boot = host.succeed(boot).strip()

                def container(words):
                    return "nixcage exec -- nixcage-container " + words

                with subtest("a microvm session runs in a kernel of its own"):
                    out = host.succeed(
                        container("enter --no-agent --substrate microvm vm /srv/proj " + boot)
                    )
                    assert host_boot not in out, (host_boot, out)

                with subtest("an exec as soon as the cage runs reaches the guest"):
                    host.succeed("runuser -u alice -- ssh-agent -a /tmp/alice-agent.sock")
                    host.succeed(
                        container(
                            "enter --auth-sock /tmp/alice-agent.sock"
                            + " --setenv NIXCAGE_PATH_PREFIX=${pkgs.hello}/bin"
                            + " vm /srv/proj sleep 120"
                        )
                        + " >/tmp/session.log 2>&1 &"
                    )
                    host.wait_until_succeeds(
                        container("status vm") + " | grep -q '^running'", timeout=60
                    )
                    out = host.succeed(container("exec vm -- " + boot))
                    assert host_boot not in out, (host_boot, out)

                with subtest("an exec has the PATH the session was asked for"):
                    out = host.succeed(container("exec vm -- sh -c 'command -v hello'"))
                    assert "${pkgs.hello}/bin/hello" in out, out

                with subtest("the session reaches the caller's agent and leaves it theirs"):
                    before = host.succeed("stat -c %u /tmp/alice-agent.sock").strip()
                    # 1 is an agent with no keys; 2 is no agent reached.
                    host.wait_until_succeeds(
                        container("exec vm -- sh -c 'ssh-add -l; test $? = 1'"), timeout=30
                    )
                    after = host.succeed("stat -c %u /tmp/alice-agent.sock").strip()
                    assert after == before, (after, before)

                with subtest("stop ends the guest"):
                    host.succeed(container("stop vm"))
                    host.succeed(container("status vm") + " | grep -qx stopped")
              '';
            };
          };

          devShells.default = pkgs.mkShell {
            buildInputs = with pkgs; [
              bash
              jq
              shellcheck
              bats
              bats.libraries.bats-support
              bats.libraries.bats-assert
              openssh
              ## The worktree tests build real repositories rather than
              ## stubbing git, so it belongs in the shell.
              git
            ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              export PATH="$PWD:$PATH"
            '';
          };
        };

      flake.overlays.default = final: _prev: {
        nixcage = import ./package.nix { pkgs = final; };
      };

      flake.nixosModules.nixcage = import ./modules/nixcage.nix;
      flake.nixosModules.host = import ./modules/host.nix;

      flake.templates.config = {
        path = ./templates/config;
        description = "nixcage shared VM configuration flake";
      };
      ## The documented bootstrap is plain 'nix flake new -t <nixcage>',
      ## which resolves templates.default.
      flake.templates.default = {
        path = ./templates/config;
        description = "nixcage shared VM configuration flake";
      };
    };
}
