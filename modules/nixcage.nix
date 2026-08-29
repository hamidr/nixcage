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
      default = "virtiofs";
      description = "Share protocol for workspace roots: virtiofs on Linux hosts, 9p on macOS.";
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
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -f /var/lib/nixcage/age.key ]; then
          umask 077
          ${pkgs.age}/bin/age-keygen -o /var/lib/nixcage/age.key
        fi
      '';
    };

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
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
