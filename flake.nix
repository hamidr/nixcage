{
  description = "nixcage — Sandboxed Nix environments with direnv integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.callPackage ./default.nix { };

        # Dev shell for working on nixcage itself
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
        };
      }
    );
}
