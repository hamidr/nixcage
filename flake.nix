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
        { pkgs, lib, ... }:
        let
          runtimeDeps = with pkgs; [
            jq
            coreutils
            gnused
            bash
            openssh
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
