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
                version = "5.0.0";

                src = ./.;

                nativeBuildInputs = [ pkgs.makeWrapper ];

                installPhase = ''
                  mkdir -p $out/bin
                  cp nixcage $out/bin/nixcage
                  chmod +x $out/bin/nixcage

                  wrapProgram $out/bin/nixcage \
                    --prefix PATH : ${lib.makeBinPath runtimeDeps} \
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
            cage = pkgs.testers.runNixOSTest {
              name = "nixcage-enters-a-cage";

              nodes.declared = {
                imports = [ inputs.self.nixosModules.host ];
                nixcage.workspaceRoots = [ "/srv" ];
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
                    declared.succeed("mkdir -p /srv/proj")
                    declared.succeed("cd /srv/proj && nixcage enter -- true")
                    record = declared.succeed(
                        "cat /var/lib/nixcage/containers/*/placement"
                    )
                    assert '"declared":true' in record, record

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
            version = "5.0.0";

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
