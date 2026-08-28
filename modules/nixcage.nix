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

  ## Minimal userland for project containers. Containers hold no system of
  ## their own -- this profile plus the read-only store bind is everything.
  containerProfile = pkgs.buildEnv {
    name = "nixcage-container-profile";
    paths = with pkgs; [
      bashInteractive
      coreutils
      nix
      git
      cacert
    ];
  };

  ## Guest-side container manager. The host CLI only ever calls this over
  ## SSH; all nspawn mechanics stay inside the VM where they are testable
  ## as one Nix-built script.
  nixcageContainer = pkgs.writeShellApplication {
    name = "nixcage-container";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gnugrep
    ];
    text = ''
      STATE_DIR=/var/lib/nixcage
      PROFILE=/etc/nixcage/profile
      SECRET_ENV=/etc/nixcage/secret-env

      die() { echo "nixcage-container: $*" >&2; exit 1; }

      [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"

      ## Render nixcage.secretEnv (VAR=secretname lines) into -E VAR=value
      ## nspawn arguments. Secrets live in /run/secrets (sops-nix, tmpfs).
      secret_env_args() {
        [ -f "$SECRET_ENV" ] || return 0
        while IFS='=' read -r var secret; do
          [ -n "$var" ] || continue
          if [ -r "/run/secrets/$secret" ]; then
            printf -- '--setenv=%s=%s\n' "$var" "$(cat "/run/secrets/$secret")"
          else
            echo "nixcage-container: secret '$secret' for $var not found; skipping" >&2
          fi
        done <"$SECRET_ENV"
      }

      ## A per-session rootfs skeleton is a few kilobytes; separate ones let
      ## concurrent sessions of the same project coexist because nspawn
      ## takes an exclusive lock on its directory tree.
      make_rootfs() {
        local root="$1"
        mkdir -p "$root"/{etc,tmp,root,workspace,nix,proc,sys,dev,run,var/empty}
        chmod 1777 "$root/tmp"
        echo 'NAME=nixcage' >"$root/etc/os-release"
        cp /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true
        cat >"$root/etc/passwd" <<'EOF'
      root:x:0:0:root:/root:/bin/sh
      nobody:x:65534:65534:nobody:/var/empty:/bin/sh
      EOF
        cat >"$root/etc/group" <<'EOF'
      root:x:0:
      nogroup:x:65534:
      EOF
        cat >"$root/etc/nsswitch.conf" <<'EOF'
      passwd: files
      group: files
      hosts: files dns
      EOF
      }

      cmd_enter() {
        local name="$1" project="$2"
        shift 2
        [ -d "$project" ] || die "project directory not found in VM: $project"

        local cdir="$STATE_DIR/containers/$name"
        local home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"

        local rootfs="$cdir/session-$$"
        make_rootfs "$rootfs"
        trap 'rm -rf "$rootfs"' EXIT

        local shell_cmd
        if [ "$#" -gt 0 ]; then
          shell_cmd="exec nix develop --command \"\$@\""
          set -- placeholder "$@"
        else
          shell_cmd="exec nix develop"
        fi

        local env_args=()
        while IFS= read -r arg; do
          env_args+=("$arg")
        done < <(secret_env_args)

        systemd-nspawn --quiet --register=no \
          --directory="$rootfs" \
          --machine="$name" \
          --bind-ro=/nix/store \
          --bind-ro=/nix/var/nix/db \
          --bind=/nix/var/nix/daemon-socket \
          --bind="$project:/workspace" \
          --bind="$home:/root" \
          --chdir=/workspace \
          --setenv=HOME=/root \
          --setenv=PATH="$PROFILE/bin" \
          --setenv=NIX_REMOTE=daemon \
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          --setenv=TERM="''${TERM:-xterm}" \
          "''${env_args[@]}" \
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
      }

      cmd_list() {
        [ -d "$STATE_DIR/containers" ] || return 0
        ls -1 "$STATE_DIR/containers"
      }

      cmd_rm() {
        local name="$1"
        rm -rf "$STATE_DIR/containers/$name" "$STATE_DIR/homes/$name"
      }

      cmd="''${1:-}"
      shift || true
      case "$cmd" in
      enter) cmd_enter "$@" ;;
      list) cmd_list ;;
      rm) cmd_rm "$@" ;;
      *) die "usage: nixcage-container enter <name> <project> [cmd...] | list | rm <name>" ;;
      esac
    '';
  };
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
      nixcageContainer
      pkgs.git
      pkgs.age
    ];

    environment.etc."nixcage/profile".source = containerProfile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );

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
