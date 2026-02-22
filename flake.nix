{
  description = "nixcage — Sandboxed Nix environments with direnv integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
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
          runtimeDeps =
            with pkgs;
            [
              jq
              coreutils
              gnused
              bash
              direnv
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [
              bubblewrap
              strace
            ];
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "nixcage";
            version = "0.4.1";

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
              description = "Sandboxed Nix environments with direnv integration";
              license = lib.licenses.gpl3Only;
              platforms = lib.platforms.unix;
            };
          };

          devShells.default = pkgs.mkShell {
            buildInputs =
              with pkgs;
              [
                bash
                jq
                shellcheck
                direnv
                bats
                bats.libraries.bats-support
                bats.libraries.bats-assert
              ]
              ++ lib.optionals pkgs.stdenv.isLinux [
                bubblewrap
                strace
              ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

          };
        };

      flake.overlays.default = final: _prev: {
        nixcage =
          let
            runtimeDeps =
              [
                final.jq
                final.coreutils
                final.gnused
                final.bash
                final.direnv
              ]
              ++ final.lib.optionals final.stdenv.isLinux [
                final.bubblewrap
                final.strace
              ];
          in
          final.stdenv.mkDerivation {
            pname = "nixcage";
            version = "0.4.1";

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
              description = "Sandboxed Nix environments with direnv integration";
              license = final.lib.licenses.gpl3Only;
              platforms = final.lib.platforms.unix;
            };
          };
      };
    };
}
