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

  ## Where everything nixcage keeps in the VM lives: the session homes, the
  ## age identity, and every directory it hands to a principal. One name
  ## because the storage service, the volumes and the guest script must agree
  ## on it.
  stateDir = "/var/lib/nixcage";

  ## The dataset mounted there, and the parent of every dataset under it.
  stateDataset = "nixcage/state";
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
        already exist here.
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
      hostId = lib.mkOption {
        type = lib.types.strMatching "[0-9a-f]{8}";
        default = "6e697863";
        description = ''
          The host id ZFS requires, as eight hex digits. It exists to stop two
          machines importing the same pool; this pool is a file only this VM
          ever opens, so the default is fine and is only an option because a
          fixed value would be wrong to hard-code.
        '';
      };
      zfsArcMax = lib.mkOption {
        type = lib.types.ints.positive;
        default = 512;
        description = ''
          Ceiling in MiB on the ZFS cache. Unbounded it would take half the
          VM's memory, which belongs to the builds and agents the VM exists to
          run.
        '';
      };
      legacyDataVolume = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Keep the ext4 volume nixcage stored its state on before ADR-017 and
          copy its contents into the pool on first boot. Set false once the
          migration has happened -- the message naming what was copied is
          printed by the storage service -- and the old image can then be
          deleted from the state directory.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
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
          ## The pool device, unmounted here and taken over by the storage
          ## service. microvm.nix makes a filesystem on every volume it
          ## creates and has no mkfs.zfs to make one with, so the image
          ## arrives carrying an ext4 superblock that zpool overwrites. It is
          ## found by serial because a drive letter moves when the volume list
          ## changes.
          image = "nixcage-pool.img";
          mountPoint = null;
          serial = "nixcage-pool";
          size = cfg.vm.diskSize;
        }
      ]
      ++ lib.optional cfg.vm.legacyDataVolume {
        image = "nixcage-data.img";
        mountPoint = "/var/lib/nixcage.legacy";
        size = cfg.vm.diskSize;
      };

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

    ## Rendered only when a uid range is declared: an ordinary session never
    ## reads it, and the uid and storage verbs refuse to answer without it.
    environment.etc."nixcage/container" = lib.mkIf (cfg.principalUidRange != null) {
      text = ''
        PRINCIPAL_UID_BASE=${toString cfg.principalUidRange.base}
        PRINCIPAL_UID_SIZE=${toString cfg.principalUidRange.size}
        STORAGE_DATASET=${stateDataset}
      '';
    };

    environment.etc."nixcage/profile".source = container.profile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );

    ## Storage (ADR-017). Everything nixcage keeps -- every session home and
    ## every directory it hands out -- lives on a ZFS pool of the VM's own.
    ## ext4 was losing whole files when the VM was stopped without a clean
    ## shutdown, and it cannot bound what any one of them writes.
    boot = {
      supportedFilesystems.zfs = true;
      ## ZFS tracks kernel releases behind the newest one, and a VM that fails
      ## to build is worse than a VM one release back. mkDefault, so a config
      ## flake that knows better can say so.
      kernelPackages = lib.mkDefault pkgs.linuxPackages;
      ## Uncapped, the ARC would take half of a VM whose memory belongs to the
      ## builds and agents it exists to run.
      kernelParams = [ "zfs.zfs_arc_max=${toString (cfg.vm.zfsArcMax * 1048576)}" ];
    };
    networking.hostId = cfg.vm.hostId;

    systemd.services.nixcage-storage = {
      description = "Import or create the nixcage ZFS pool";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-modules-load.service"
      ] ++ lib.optional cfg.vm.legacyDataVolume "var-lib-nixcage.legacy.mount";
      requires = lib.optional cfg.vm.legacyDataVolume "var-lib-nixcage.legacy.mount";
      before = [
        "nixcage-age-key.service"
        "sshd.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        config.boot.zfs.package
        pkgs.coreutils
        pkgs.util-linux
      ];
      script = ''
        set -eu
        device=/dev/disk/by-id/virtio-nixcage-pool

        if ! zpool list -H nixcage >/dev/null 2>&1; then
          if ! zpool import -N -d /dev/disk/by-id nixcage >/dev/null 2>&1; then
            ## A pool that is there and will not import is a fault to look at,
            ## never a device to reformat: zpool create would take every
            ## principal's state with it.
            if zdb -l "$device" >/dev/null 2>&1; then
              echo "nixcage: a pool exists on $device but will not import; refusing to recreate it" >&2
              exit 1
            fi
            ## posixacl and xattr=sa are not tuning: what a caller does with
            ## a directory nixcage hands it may need a POSIX ACL, and ZFS
            ## rejects setfacl without them.
            zpool create -f \
              -o ashift=12 \
              -O compression=zstd \
              -O atime=off \
              -O acltype=posixacl \
              -O xattr=sa \
              -O mountpoint=none \
              nixcage "$device"
          fi
        fi

        if ! zfs list -H nixcage/state >/dev/null 2>&1; then
          zfs create -o mountpoint=${stateDir} nixcage/state
        fi
        zfs mount -a
        mountpoint -q ${stateDir}
        chmod 0755 ${stateDir}
      ''
      + lib.optionalString cfg.vm.legacyDataVolume ''

        ## One-way migration off the ext4 volume, once. An empty pool beside a
        ## volume with contents is the only state this can act on, so a later
        ## boot cannot copy over work done since.
        legacy=${stateDir}.legacy
        if [ -d "$legacy" ] &&
          [ -z "$(ls -A ${stateDir})" ] &&
          [ -n "$(ls -A "$legacy")" ]; then
          echo "nixcage: migrating state from the ext4 volume into the pool"
          cp -a "$legacy"/. ${stateDir}/
          echo "nixcage: migrated $(ls -A ${stateDir} | tr '\n' ' ')"
          echo "nixcage: set nixcage.vm.legacyDataVolume = false to drop the old volume"
        fi
      '';
    };

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
      after = [ "nixcage-storage.service" ];
      requires = [ "nixcage-storage.service" ];
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
      after = [ "nixcage-storage.service" ];
      requires = [ "nixcage-storage.service" ];
    };

    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };

      ## Store optimisation is deliberately absent. Hardlinking duplicate paths
      ## would suit a VM whose projects overlap heavily, but microvm.nix asserts
      ## against it wherever writableStoreOverlay is set, which this module
      ## always sets, so enabling it makes the VM fail to build rather than
      ## build smaller.
      ##

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
    }
  ];
}
