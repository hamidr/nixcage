## Shared container layer: the minimal userland profile and the
## nixcage-container script that owns all nspawn mechanics. Used by the
## VM module (macOS path) and the host module (Linux path) unchanged --
## the script only assumes a Linux system with /var/lib/nixcage,
## /etc/nixcage/{profile,secret-env}, and a nix daemon socket.
{ pkgs }:
let
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
      ## Resolve the /etc symlink to its store path: the container has its
      ## own /etc, but the store bind makes store paths valid inside.
      PROFILE="$(readlink -f /etc/nixcage/profile)"
      SECRET_ENV=/etc/nixcage/secret-env

      die() { echo "nixcage-container: $*" >&2; exit 1; }

      [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"

      ## Names reach root-level rm -rf and nspawn --machine; only the
      ## derived-name alphabet is allowed.
      check_name() {
        printf '%s' "$1" | grep -qE '^[a-zA-Z0-9-]+$' || die "invalid container name: $1"
      }

      ## Render nixcage.secretEnv (VAR=secretname lines) into an export
      ## file inside the session rootfs. Values must never appear in
      ## nspawn's argv, where any local user could read them from
      ## /proc/<pid>/cmdline; %q also keeps multiline secrets intact.
      write_secret_env() {
        local out="$1"
        : >"$out"
        chmod 600 "$out"
        [ -f "$SECRET_ENV" ] || return 0
        local var secret
        while IFS='=' read -r var secret; do
          [ -n "$var" ] || continue
          if [ -r "/run/secrets/$secret" ]; then
            printf 'export %s=%q\n' "$var" "$(cat "/run/secrets/$secret")" >>"$out"
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
        ## nspawn refuses a rootfs without /usr ("doesn't look like it has
        ## an OS tree").
        mkdir -p "$root"/{etc,usr,tmp,root,workspace,nix,proc,sys,dev,run,var/empty}
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
        check_name "$name"
        [ -d "$project" ] || die "project directory not found: $project"

        ## The container is mapped onto the project owner rather than run as
        ## real root: nix's libgit2 refuses a repository owned by a different
        ## uid, and every project directory belongs to the invoking user.
        local owner_uid owner_gid
        owner_uid="$(stat -c %u "$project")"
        owner_gid="$(stat -c %g "$project")"

        local cdir="$STATE_DIR/containers/$name"
        local home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"
        ## The home is the container's /root and holds whatever the session
        ## writes there, so it is private to the mapped user.
        chown "$owner_uid:$owner_gid" "$home"
        chmod 700 "$home"

        local rootfs="$cdir/session-$$"
        make_rootfs "$rootfs"
        ## Expand now: locals are out of scope when the EXIT trap fires.
        # shellcheck disable=SC2064
        trap "rm -rf '$rootfs'" EXIT

        ## The environment is chosen inside the container, where the project
        ## is actually bound; the library is referenced by store path because
        ## the store is bound read-only there. bash -c consumes the first
        ## argument as $0, so a placeholder always precedes the user command.
        local shell_cmd=". /etc/nixcage-env 2>/dev/null || true; \
          . ${./dev-shell.sh}; \
          nixcage_enter_shell \"\$@\""
        set -- placeholder "$@"

        write_secret_env "$rootfs/etc/nixcage-env"
        ## Everything the skeleton contains was created by root and would
        ## otherwise appear as an unmapped nobody inside the container.
        chown -R "$owner_uid:$owner_gid" "$rootfs"

        systemd-nspawn --quiet --register=no \
          --directory="$rootfs" \
          --machine="$name" \
          --private-users="$owner_uid:1" \
          --private-users-ownership=off \
          --bind-ro=/nix/store \
          --bind-ro=/nix/var/nix/db \
          --bind=/nix/var/nix/daemon-socket \
          --bind="$project:/workspace" \
          --bind="$home:/root" \
          --chdir=/workspace \
          --setenv=HOME=/root \
          --setenv=PATH="$PROFILE/bin" \
          --setenv=NIX_REMOTE=daemon \
          --setenv=NIX_CONFIG='experimental-features = nix-command flakes' \
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          --setenv=TERM="''${TERM:-xterm}" \
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
      }

      cmd_list() {
        [ -d "$STATE_DIR/containers" ] || return 0
        ls -1 "$STATE_DIR/containers"
      }

      cmd_rm() {
        local name="$1"
        check_name "$name"
        rm -rf "$STATE_DIR/containers/''${name:?}" "$STATE_DIR/homes/''${name:?}"
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
  profile = containerProfile;
  script = nixcageContainer;
}
