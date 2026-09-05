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

    storage = lib.mkOption {
      type = lib.types.submodule {
        options = {
          dataset = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "tank/nixcage";
            description = ''
              The ZFS dataset mounted at /var/lib/nixcage, if this host keeps
              nixcage's state on one. Set it and every directory nixcage hands
              out becomes a child dataset, which is what makes a quota on one
              possible and what keeps an unclean shutdown from truncating what
              was written there.
              Left null, nixcage uses ordinary directories and behaves exactly
              as before; nothing here requires ZFS of a Linux host (ADR-017).
            '';
          };
        };
      };
      default = { };
      description = "Where nixcage keeps its state on this host.";
    };

    principalUidRange = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            base = lib.mkOption {
              type = lib.types.ints.unsigned;
              example = 700000;
              description = "First uid a principal may be allocated.";
            };
            size = lib.mkOption {
              type = lib.types.ints.positive;
              default = 64;
              description = "How many uids the range covers.";
            };
          };
        }
      );
      default = null;
      description = ''
        The uid range `nixcage-container uid` allocates from (ADR-004). A
        principal is whatever a caller wants a durable uid for; nixcage only
        promises that one name always answers with one number and that a
        forgotten name's number is never reissued, so nothing new can inherit
        a dead principal's files. The range must not overlap accounts that
        already exist on this host.
      '';
    };

    git = lib.mkOption {
      type = lib.types.submodule {
        options = {
          userName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Ada Lovelace";
            description = "Committer name every session uses. No identity is rendered unless both this and userEmail are set.";
          };
          userEmail = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ada@example.org";
            description = "Committer email every session uses.";
          };
          signing.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Sign commits and tags through the ssh-agent the CLI forwards
              into the session. No key material is copied in, and a session
              entered without a reachable agent simply fails to sign.
            '';
          };
        };
      };
      default = { };
      description = "Git identity and signing for container sessions.";
    };
  };

  config = lib.mkMerge [
    {
    environment.systemPackages = [ container.script ];

    ## Rendered only when an identity exists: an incomplete gitconfig would
    ## replace git's own "who are you" error with a stranger one.
    environment.etc."nixcage/gitconfig" =
      lib.mkIf (cfg.git.userName != null && cfg.git.userEmail != null)
        {
          text = container.gitConfigText cfg.git;
        };

    ## Rendered only when a uid range is declared: an ordinary session never
    ## reads it, and the uid and storage verbs refuse to answer without it.
    environment.etc."nixcage/container" = lib.mkIf (cfg.principalUidRange != null) {
      text = ''
        PRINCIPAL_UID_BASE=${toString cfg.principalUidRange.base}
        PRINCIPAL_UID_SIZE=${toString cfg.principalUidRange.size}
        STORAGE_DATASET=${lib.optionalString (cfg.storage.dataset != null) cfg.storage.dataset}
      '';
    };

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
    }
  ];
}
