## nixcage NixOS module: options plus base configuration for the single
## shared VM. Imported by the user's config flake together with
## microvm.nixosModules.microvm (and optionally sops-nix).
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
        Absolute host directories shared into the VM. Each root is mounted
        at the same absolute path inside the VM, so a project's path is
        identical on both sides. Only flake directories under a root can be
        entered.
      '';
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22022;
      description = "Host port forwarded to the VM's SSH daemon.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        SSH public keys allowed to enter the VM. The host CLI generates a
        keypair at ~/.local/state/nixcage/id_ed25519 on first start and
        prints the public key to paste here.
      '';
    };

    shareProto = lib.mkOption {
      type = lib.types.enum [
        "virtiofs"
        "9p"
      ];
      ## Since ADR-003 this VM only runs on macOS hosts, where virtiofsd
      ## does not exist; 9p is the only working default.
      default = "9p";
      description = "Share protocol for workspace roots: 9p on macOS hosts, virtiofs on Linux hosts.";
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        ANTHROPIC_API_KEY = "anthropic";
      };
      description = ''
        Environment variable to sops secret name mapping. Each container
        session gets the variable set from /run/secrets/<name>. The host
        environment is never read.
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

    vm = {
      cpus = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Number of virtual CPUs.";
      };
      mem = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4096;
        description = "VM memory in MiB.";
      };
      diskSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20480;
        description = "Size in MiB of each persistent volume (Nix store overlay and container data).";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = ''
          nixcage.authorizedKeys is empty: nobody could SSH into the VM and
          'nixcage enter' would hang until timeout. Paste the public key the
          CLI prints on first run (~/.local/state/nixcage/id_ed25519.pub).
        '';
      }
    ];

    ## The VM owns its store: the closure ships as a read-only image and
    ## builds land in a persistent writable overlay. The host store is
    ## never shared into the guest.
    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.vm.cpus;
      mem = cfg.vm.mem;
      writableStoreOverlay = "/nix/.rw-store";

      volumes = [
        {
          image = "nixcage-store.img";
          mountPoint = "/nix/.rw-store";
          size = cfg.vm.diskSize;
        }
        {
          image = "nixcage-data.img";
          mountPoint = "/var/lib/nixcage";
          size = cfg.vm.diskSize;
        }
      ];

      shares = lib.imap0 (i: root: {
        tag = "ws${toString i}";
        source = root;
        mountPoint = root;
        proto = cfg.shareProto;
      }) cfg.workspaceRoots;

      interfaces = [
        {
          type = "user";
          id = "nixcage0";
          mac = "02:00:00:00:00:01";
        }
      ];

      forwardPorts = [
        {
          from = "host";
          host.port = cfg.sshPort;
          guest.port = 22;
        }
      ];
    };

    environment.systemPackages = [
      container.script
      pkgs.git
      pkgs.age
    ];

    ## Rendered only when an identity exists: an incomplete gitconfig would
    ## replace git's own "who are you" error with a stranger one.
    environment.etc."nixcage/gitconfig" =
      lib.mkIf (cfg.git.userName != null && cfg.git.userEmail != null)
        {
          text = container.gitConfigText cfg.git;
        };

    environment.etc."nixcage/profile".source = container.profile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );

    ## Generate the age identity on the data volume at first boot so the
    ## user can read the public key (nixcage status) before declaring any
    ## sops secret. sops-nix's own generateKey only runs once secrets
    ## exist, which is too late for that bootstrap.
    systemd.services.nixcage-age-key = {
      description = "Generate the nixcage age identity";
      wantedBy = [ "multi-user.target" ];
      ## Without the mount ordering the key lands on the ephemeral rootfs
      ## and is shadowed once the volume mounts (observed as an empty
      ## age.key). -s, not -f: an empty file from such a race must not
      ## satisfy the guard.
      after = [ "var-lib-nixcage.mount" ];
      requires = [ "var-lib-nixcage.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -s /var/lib/nixcage/age.key ]; then
          umask 077
          rm -f /var/lib/nixcage/age.key
          ${pkgs.age}/bin/age-keygen -o /var/lib/nixcage/age.key
        fi
      '';
    };

    ## sshd generates its persistent host key in preStart; force it after
    ## the data volume mount or the first boot serves a throwaway tmpfs key
    ## and every later boot fails host key verification.
    systemd.services.sshd = {
      after = [ "var-lib-nixcage.mount" ];
      requires = [ "var-lib-nixcage.mount" ];
    };

    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];

        ## Every project's devShell is a separate closure in the same overlay,
        ## and they overlap heavily; hardlinking the duplicates is most of what
        ## keeps a many-project VM from filling one.
        auto-optimise-store = lib.mkDefault true;
      };

      ## The store overlay is a fixed-size volume that only grows: containers
      ## build into it for the life of the VM and nothing else prunes it.
      ## Every value is mkDefault, so a config flake can lengthen the window,
      ## change the schedule, or turn collection off entirely.
      ##
      ## 'nix develop' keeps only a temporary root, so a collection between
      ## sessions drops the devShell closures and the next enter refetches
      ## them. That is the cost of not filling the volume.
      gc = {
        automatic = lib.mkDefault true;
        dates = lib.mkDefault "weekly";
        options = lib.mkDefault "--delete-older-than 30d";
      };
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
      ## On the data volume: the rootfs is ephemeral, and a stable host key
      ## lets the CLI verify every boot after the first instead of blindly
      ## re-accepting a fresh key each time.
      hostKeys = [
        {
          path = "/var/lib/nixcage/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    users.users.nixcage = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    security.sudo.wheelNeedsPassword = false;

    networking.hostName = "nixcage";

    system.stateVersion = "24.11";
  };
}
