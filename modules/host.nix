## nixcage host module for Linux: project containers run directly on this
## machine, so there is no VM. Renders /etc/nixcage/config for the CLI and
## installs the same container layer the VM uses. Secrets come from the
## host's own sops-nix setup under /run/secrets.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcage;
  container = import ./container.nix { inherit pkgs; };
in
{
  options.nixcage = {
    workspaceRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "/home/me/Src" ];
      description = ''
        Absolute directories whose flake subdirectories can be entered.
        Containers bind only their own project subdirectory.
      '';
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        ANTHROPIC_API_KEY = "anthropic";
      };
      description = ''
        Environment variable to sops secret name mapping. Each container
        session gets the variable set from this host's /run/secrets/<name>.
      '';
    };
  };

  config = {
    environment.systemPackages = [ container.script ];

    environment.etc."nixcage/profile".source = container.profile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );
    environment.etc."nixcage/config".text = ''
      WORKSPACE_ROOTS=${lib.concatStringsSep ":" cfg.workspaceRoots}
    '';

    ## The container homes and skeletons live where the VM keeps them, so
    ## the container script needs no platform branch.
    systemd.tmpfiles.rules = [
      "d /var/lib/nixcage 0755 root root -"
    ];
  };
}
