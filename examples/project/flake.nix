## Example project flake. This is a completely ordinary flake -- nixcage
## needs nothing project-specific. 'nixcage enter' runs devShells.default
## inside this project's container.
{
  description = "Example nixcage project";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      ## claude-code is unfree; legacyPackages never allows unfree, so the
      ## shell instantiates its own nixpkgs with the permission granted.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = with (pkgsFor system); [
            ## Your toolchain -- and the AI agent, if you want one. nixcage
            ## installs nothing into containers.
            claude-code
            nodejs_22
          ];
        };
      });
    };
}
