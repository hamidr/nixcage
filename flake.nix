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
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "nixcage";
            version = "2.1.0";

            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin
              cp nixcage $out/bin/nixcage
              chmod +x $out/bin/nixcage

              wrapProgram $out/bin/nixcage \
                --prefix PATH : ${lib.makeBinPath runtimeDeps}
            '';

            meta = {
              description = "One shared NixOS microVM with per-project containers for AI coding agents";
              license = lib.licenses.gpl3Only;
              platforms = lib.platforms.unix;
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
            version = "2.1.0";

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
