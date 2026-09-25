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

            ## A machine (ADR-026): a microVM that is a nixcage host, with
            ## an nspawn cage inside it reached by --machine. Nested KVM,
            ## as the session check above; `nix build .#hostChecks.machine`.
            machine = pkgs.testers.runNixOSTest {
              name = "nixcage-machine";

              nodes.host = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
                nixcage.machines.m1 = {
                  memory = "1536M";
                  cpus = 2;
                  diskSize = "2G";
                  uidSlice.base = 900000;
                  shares = [
                    { path = "/srv/ro"; }
                    {
                      path = "/srv/rw";
                      writable = true;
                    }
                  ];
                };
                virtualisation.fileSystems."/srv/rw" = {
                  device = "tmpfs";
                  fsType = "tmpfs";
                  options = [
                    "nosuid"
                    "nodev"
                    "mode=0777"
                  ];
                };
                systemd.tmpfiles.rules = [ "d /srv/ro 0755 root root -" ];
                ## The host bridge both machines are placed on, and a
                ## service on its address that a cage inside one reaches.
                nixcage.bridges.nc0 = {
                  address = "10.66.0.1";
                  prefix = 24;
                };
                nixcage.machines.m1.placement = {
                  bridge = "nc0";
                  addresses = [
                    "10.66.0.2"
                    "10.66.0.11"
                  ];
                };
                nixcage.machines.m1.modules = [
                  {
                    nixcage.bridges.mb = {
                      address = "10.66.0.2";
                      prefix = 24;
                      uplink = "eth0";
                    };
                  }
                ];
                nixcage.machines.m2 = {
                  memory = "1024M";
                  diskSize = "1G";
                  uidSlice.base = 1000000;
                  placement = {
                    bridge = "nc0";
                    addresses = [
                      "10.66.0.3"
                      "10.66.0.21"
                    ];
                  };
                  modules = [
                    {
                      nixcage.bridges.mb = {
                        address = "10.66.0.3";
                        prefix = 24;
                        uplink = "eth0";
                      };
                    }
                  ];
                };
                systemd.services.echo = {
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network-online.target" ];
                  wants = [ "network-online.target" ];
                  serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:7000,bind=10.66.0.1,fork,reuseaddr SYSTEM:'echo ok'";
                };
                networking.firewall.interfaces.nc0.allowedTCPPorts = [ 7000 ];
                ## A person whose agent a cage in the machine is handed.
                users.users.alice.isNormalUser = true;
                environment.systemPackages = [ self'.packages.default ];
                virtualisation.memorySize = 5120;
                virtualisation.cores = 2;
              };

              testScript = ''
                import time
                start_all()
                host.wait_for_unit("multi-user.target")
                boot = "cat /proc/sys/kernel/random/boot_id"
                host_boot = host.succeed(boot).strip()

                def container(words):
                    return "nixcage exec -- nixcage-container " + words

                with subtest("a machine comes up and says so"):
                    host.succeed(container("machine up m1"))
                    host.succeed(container("machine status m1") + " | grep -qx ready")

                with subtest("a machine is a kernel of its own"):
                    m1_boot = host.succeed(container("machine exec m1 " + boot)).strip()
                    assert m1_boot != host_boot, (m1_boot, host_boot)

                with subtest("a cage entered with --machine runs in the machine's kernel"):
                    # nspawn gives a container a boot id of its own, so the
                    # kernel is told apart by its uptime: the machine's
                    # kernel started well after the host's.
                    uptime = "cut -d' ' -f1 /proc/uptime"
                    host.succeed(container("machine exec m1 mkdir -p /srv/p"))
                    cage_up = float(host.succeed(
                        container("enter --machine m1 --no-agent c1 /srv/p " + uptime)
                    ).strip())
                    m1_up = float(host.succeed(container("machine exec m1 " + uptime)).strip())
                    host_up = float(host.succeed(uptime).strip())
                    assert abs(m1_up - cage_up) < 10, (cage_up, m1_up)
                    assert host_up - cage_up > 10, (cage_up, host_up)
                    host.succeed(container("list --machine m1") + " | grep -qx c1")
                    host.succeed(container("list --machine m1 --json") + " | ${pkgs.jq}/bin/jq -e 'select(.name == \"c1\")'")
                    host.fail("test -d /var/lib/nixcage/containers/c1")

                with subtest("a cage in a machine sees the closure the host computed, and no more"):
                    base = host.succeed("sed -n 's/^STORE_BASE=//p' /etc/nixcage/machines/m1").strip()
                    want = int(host.succeed("nix-store -qR " + base + " | wc -l").strip())
                    seen = int(host.succeed(
                        container("enter --machine m1 --no-agent c1 /srv/p sh -c 'ls /nix/store | wc -l'")
                    ).strip())
                    assert seen == want, (seen, want)

                with subtest("a quota inside a machine is refused, and storage without one is given"):
                    host.fail(container("storage --machine m1 ensure /var/lib/nixcage/q 1000 1G"))
                    host.succeed(container("storage --machine m1 ensure /var/lib/nixcage/q 1000"))
                    host.succeed(container("machine exec m1 stat -c %u /var/lib/nixcage/q") + " | grep -qx 1000")

                with subtest("a cage on the host cannot take a machine's name"):
                    host.succeed("mkdir -p /srv/q")
                    host.fail(container("enter --no-agent m1 /srv/q true"))

                with subtest("netns with --machine is refused"):
                    host.fail(container("netns --machine m1 c1"))

                with subtest("a read-only share cannot be written from the machine"):
                    host.succeed("echo hi > /srv/ro/seen")
                    host.succeed(container("machine exec m1 grep -qx hi /srv/ro/seen"))
                    host.fail(container("machine exec m1 touch /srv/ro/written"))
                    host.fail("test -e /srv/ro/written")

                with subtest("what guest root writes on a share is the slice's base here, never root"):
                    host.succeed(container("machine exec m1 touch /srv/rw/f"))
                    assert host.succeed("stat -c %u:%g /srv/rw/f").strip() == "900000:900000"
                    host.succeed(container("machine exec m1 chown 0:0 /srv/rw/f"))
                    assert host.succeed("stat -c %u /srv/rw/f").strip() == "900000"
                    host.succeed(container("machine exec m1 chmod u+s /srv/rw/f"))
                    host.fail("test \"$(stat -c %u /srv/rw/f)\" = 0")

                with subtest("an id beyond the slice cannot be given to a file on a share"):
                    host.fail(container("machine exec m1 chown 70000 /srv/rw/f"))
                    assert host.succeed("stat -c %u /srv/rw/f").strip() == "900000"

                with subtest("a cage in a machine reaches the caller's agent, which stays theirs"):
                    host.succeed("runuser -u alice -- ssh-agent -a /tmp/alice-agent.sock")
                    before = host.succeed("stat -c %u /tmp/alice-agent.sock").strip()
                    # 1 is an agent with no keys; 2 is no agent reached.
                    host.succeed(container(
                        "enter --machine m1 --auth-sock /tmp/alice-agent.sock c1 /srv/p"
                        + " sh -c 'ssh-add -l; test $? = 1'"
                    ))
                    assert host.succeed("stat -c %u /tmp/alice-agent.sock").strip() == before

                reach = "timeout 5 bash -c 'cat </dev/tcp/10.66.0.1/7000'"

                with subtest("a cage in a machine reaches the host bridge as its own address"):
                    out = host.succeed(container(
                        "enter --machine m1 --no-agent --network mb:10.66.0.11/24 net1 /srv/p " + reach
                    ))
                    assert out.strip() == "ok", out
                    host.succeed(
                        "${pkgs.nftables}/bin/nft list set bridge nixcage placements | grep -q '10.66.0.11'"
                    )

                with subtest("an address the machine was not given is dropped at the host's tap"):
                    host.fail(container(
                        "enter --machine m1 --no-agent --network mb:10.66.0.12/24 net2 /srv/p " + reach
                    ))

                with subtest("a cage in one machine does not reach a cage in another"):
                    host.succeed(container("machine up m2"))
                    host.succeed(container("machine exec m2 mkdir -p /srv/p"))
                    host.succeed(
                        container("enter --machine m2 --no-agent --network mb:10.66.0.21/24 lsn /srv/p sleep 300")
                        + " >/dev/null 2>&1 &"
                    )
                    host.wait_until_succeeds(
                        container("status --machine m2 lsn") + " | grep -q '^running'", timeout=60
                    )
                    # A refused connection is an answer: the peer is reachable
                    # and has nothing on the port. Its own machine gets one.
                    probe = "bash -c 'timeout 5 bash -c \"echo >/dev/tcp/10.66.0.21/22\" 2>&1; true'"
                    out = host.succeed(container("machine exec m2 " + probe))
                    assert "Connection refused" in out, out
                    out = host.succeed(container(
                        "enter --machine m1 --no-agent --network mb:10.66.0.11/24 net1 /srv/p " + probe
                    ))
                    assert "Connection refused" not in out, out
                    host.succeed(container("machine down m2"))
                    m2_tap = host.succeed("printf %s m2 | sha256sum | cut -c1-12").strip()
                    host.fail("ip link show nc-" + m2_tap)
                    host.fail("${pkgs.nftables}/bin/nft list set bridge nixcage placements | grep -q 10.66.0.21")

                with subtest("a machine with no cages answers list --json with nothing, which is valid"):
                    host.succeed(container("machine up m2"))
                    host.succeed(container("rm --machine m2 lsn"))
                    assert host.succeed(container("list --machine m2 --json")).strip() == ""
                    host.succeed(container("machine down m2"))

                with subtest("down stops the machine, and up finds its disk as it was"):
                    fs = host.succeed(container("machine exec m1 findmnt -no FSTYPE,SOURCE /var/lib/nixcage")).split()
                    assert fs == ["ext4", "/dev/vda"], fs
                    host.succeed(container("machine exec m1 touch /var/lib/nixcage/kept"))
                    host.succeed(container("machine down m1"))
                    host.succeed(container("machine status m1") + " | grep -qx off")
                    host.fail(container("list --machine m1"))
                    host.succeed(container("machine up m1"))
                    host.succeed(container("machine exec m1 test -e /var/lib/nixcage/kept"))
                    host.succeed(container("machine down m1"))

                with subtest("a cage entered with --machine ends when its caller is stopped"):
                    # Found on a host (2026-09-25): an executor's stop ended
                    # its ssh clients and left every cage running in the
                    # machine, since sshd signals nothing without a tty.
                    host.succeed(container("machine up m1"))
                    host.succeed(
                        "systemd-run --unit=caller --property=KillMode=control-group "
                        + "/run/current-system/sw/bin/nixcage-container enter --machine m1 --no-agent held /srv/p sleep 600"
                    )
                    host.wait_until_succeeds(container("status --machine m1 held") + " | grep -q '^running'", timeout=60)
                    host.succeed("systemctl stop caller")
                    host.wait_until_succeeds(container("status --machine m1 held") + " | grep -qx stopped", timeout=30)

                with subtest("many forwards in a row share one connection and all answer"):
                    accepted = container("machine exec m1 systemctl show sshd-vsock.socket -p NAccepted --value")
                    before = int(host.succeed(accepted).strip())
                    host.succeed(
                        "for i in $(seq 30); do " + container("machine status m1") + " | grep -qx ready || exit 1; done"
                    )
                    after = int(host.succeed(accepted).strip())
                    # Thirty statuses are thirty probes: without the master,
                    # thirty connections; through it, none.
                    assert after - before < 5, (before, after)

                with subtest("down does not wait on a guest that stopped answering, and leaves nothing"):
                    host.succeed(container("machine up m1"))
                    # The guest's sshd over vsock is what every answer comes
                    # through; with it gone the guest says nothing at all.
                    host.execute(container("machine exec m1 systemctl stop sshd-vsock.socket 'sshd-vsock@*'"))
                    host.succeed(container("machine status m1") + " | grep -qx booting")
                    t0 = time.monotonic()
                    host.succeed(container("machine down m1"))
                    took = time.monotonic() - t0
                    assert took < 60, took
                    host.succeed(container("machine status m1") + " | grep -qx off")
                    m1_tap = host.succeed("printf %s m1 | sha256sum | cut -c1-12").strip()
                    host.fail("ip link show nc-" + m1_tap)
                    host.fail("${pkgs.nftables}/bin/nft list set bridge nixcage placements | grep -q 10.66.0.11")
                    host.fail("pgrep -f 'virtiofsd --shared-dir=/srv/r'")

                with subtest("the host holds no block device for the disk"):
                    host.fail("lsblk -rno NAME | grep -q '^loop'")
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
