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
        { pkgs, ... }:
        let
          runtimeDeps =
            with pkgs;
            [
              jq
              coreutils
              gnused
              bash
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              bubblewrap
            ];
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "nixcage";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin
              cp nixcage $out/bin/nixcage
              chmod +x $out/bin/nixcage

              wrapProgram $out/bin/nixcage \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
            '';

            meta = with pkgs.lib; {
              description = "Sandboxed Nix environments with direnv integration";
              license = licenses.gpl3Only;
              platforms = platforms.unix;
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
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                bubblewrap
              ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              git config core.hooksPath .githooks
            '';
          };
        };
    };
}
