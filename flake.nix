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
          runtimeDeps = with pkgs; [
            jq
            coreutils
            gnused
            bash
            openssh
            ## Where nothing was declared, a session's identity is whatever
            ## this user's own git answers with, so the CLI has to have one.
            git
          ];
          ## The container layer this nixcage carries. A host that imported
          ## nixosModules.host installs its own and the CLI uses that; where
          ## nothing was declared there is no other source, so the layer is
          ## part of what `nix run github:hamidr/nixcage` fetches (ADR-023).
          ## Linux only: nothing on darwin can run a cage, and container.nix
          ## asks for packages darwin does not have.
          container = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
            import ./modules/container.nix { inherit pkgs; }
          );
          ## Named across sudo rather than inherited, since sudo clears the
          ## environment (ADR-023 decision 8).
          carriedLayer = lib.optionals (container ? script) [
            "--set NIXCAGE_CONTAINER ${container.script}/bin/nixcage-container"
            "--set NIXCAGE_PROFILE ${container.profile}"
          ];
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
              default = pkgs.stdenv.mkDerivation {
                pname = "nixcage";
                version = "5.1.0";

                src = ./.;

                nativeBuildInputs = [ pkgs.makeWrapper ];

                installPhase = ''
                  mkdir -p $out/bin
                  cp nixcage $out/bin/nixcage
                  chmod +x $out/bin/nixcage

                  wrapProgram $out/bin/nixcage \
                    --prefix PATH : ${lib.makeBinPath runtimeDeps} \
                    --set NIXCAGE_DECLARATION_SH ${./modules/declaration.sh} \
                    ${lib.concatStringsSep " " carriedLayer}
                '';

                meta = {
                  description = "One shared NixOS microVM with per-project containers for AI coding agents";
                  license = lib.licenses.gpl3Only;
                  platforms = lib.platforms.unix;
                };
              };
            };

          ## The one test that boots what every other test only describes: a
          ## NixOS machine running the host module, a second running nothing
          ## but the CLI, and a cage entered on each for real. Linux only,
          ## because a NixOS test is a Linux virtual machine.
          checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
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
                    host.succeed("mkdir -p /srv/proj")
                    out = host.succeed(
                        "nixcage exec -- nixcage-container enter --uid " + first
                        + " --setenv K=V --bind-ro /srv:/srv-ro"
                        + " cage /srv/proj sh -c 'id -u; echo $K; test -e /srv-ro/proj'"
                    )
                    assert first in out, (first, out)
                    assert "V" in out, out

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
        nixcage =
          let
            runtimeDeps = [
              final.jq
              final.coreutils
              final.gnused
              final.bash
              final.openssh
            ];
          in
          final.stdenv.mkDerivation {
            pname = "nixcage";
            version = "5.1.0";

            src = ./.;

            nativeBuildInputs = [ final.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin
              cp nixcage $out/bin/nixcage
              chmod +x $out/bin/nixcage

              wrapProgram $out/bin/nixcage \
                --prefix PATH : ${final.lib.makeBinPath runtimeDeps}
            '';

            meta = {
              description = "One shared NixOS microVM with per-project containers for AI coding agents";
              license = final.lib.licenses.gpl3Only;
              platforms = final.lib.platforms.unix;
            };
          };
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
