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

      flake.overlays.default = final: _prev: {
        nixcage = final.callPackage ./package.nix { };
      };

      perSystem =
        { pkgs, ... }:
        {
          packages.default = pkgs.callPackage ./package.nix { };

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
