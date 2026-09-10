## Shared container layer: the minimal userland profile and the
## nixcage-container script that owns all nspawn mechanics. Used by the
## VM module (macOS path) and the host module (Linux path) unchanged --
## the script only assumes a Linux system with /var/lib/nixcage,
## /etc/nixcage/{profile,secret-env}, and a nix daemon socket.
{
  pkgs,
  ## What the host adds to every session's userland. A dependant that needs one
  ## more thing in every cage has no other way to put it there: enter takes
  ## binds and environment, never packages, and prepending PATH would mean
  ## reconstructing a profile path the caller does not know. Empty by default,
  ## so a host that asks for nothing gets exactly what it got before.
  extraPackages ? [ ],
}:
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
      ## coreutils carries none of these. A project with a devShell gets them
      ## from stdenv and never notices; ADR-005 makes a devShell optional, and
      ## a session without one should not be missing the ordinary text tools.
      gnused
      gnugrep
      gawk
      findutils
      ## A project that declares its environment in .envrc is entered through
      ## direnv rather than nix develop, so direnv is part of the userland
      ## every session gets.
      direnv
      ## ssh-keygen signs commits and ssh-add names the key to sign with;
      ## both talk to the forwarded agent rather than to any key on disk.
      openssh
    ]
    ++ extraPackages;
  };

  ## Guest-side container manager. The host CLI only ever calls this over
  ## SSH; all nspawn mechanics stay inside the VM where they are testable
  ## as one Nix-built script.
  ##
  ## Its three verbs are also nixcage's exported interface: `enter` builds a
  ## session out of what a caller asks for, `uid` hands out a durable number
  ## for a named principal, and `storage` gives a path to that number with a
  ## bound on it. Anything built on nixcage is built on these, so each takes
  ## argv and prints a result rather than expecting its caller to know how
  ## nixcage keeps its state.
  nixcageContainer = pkgs.writeShellApplication {
    name = "nixcage-container";
    ## The sourced helpers are store paths, which shellcheck cannot follow from
    ## inside the build. They are real shell files and the dev shell lints them
    ## directly, so following them here would add nothing and the unfollowable
    ## source is what fails the build.
    excludeShellChecks = [ "SC1091" ];
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gnugrep
      ## Resolving a linked worktree's git directories, which the project bind
      ## does not cover.
      git
      ## The ownership check on a session's home walks it, so find has to be on
      ## the script's own PATH rather than only on the system's.
      findutils
    ];
    text = ''
      ## Sourced by store path: the file is a real shell file so shellcheck
      ## and the bats suite can read it, and the store is available here.
      . ${./git-worktree.sh}
      . ${./principal-uid.sh}
      . ${./storage.sh}
      . ${./bind.sh}
      . ${./enter-args.sh}
      . ${./dev-shell.sh}

      STATE_DIR=/var/lib/nixcage
      ## Rendered by the platform module: the uid range principals are
      ## allocated from, and the dataset holding nixcage's state where there is
      ## one. Absent on a host that declares neither.
      CONTAINER_CONFIG=/etc/nixcage/container
      ## Resolve the /etc symlink to its store path: the container has its
      ## own /etc, but the store bind makes store paths valid inside.
      PROFILE="$(readlink -f /etc/nixcage/profile)"
      SECRET_ENV=/etc/nixcage/secret-env

      die() { echo "nixcage-container: $*" >&2; exit 1; }

      ## One description of the interface, used by every path that has to
      ## print it. Two would drift, and this is the only thing a caller sees
      ## at run time telling it what nixcage exports.
      usage() { echo "usage: nixcage-container enter [--uid <n>] [--user <name>] [--subject <name>] [--home <path>] [--shell <name>] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--auth-sock <path>|--no-agent] <name> <project> [cmd...] | uid <principal> [<subject>] | storage ensure <path> <uid> [quota] | list | rm <name>"; }

      [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"

      ## Names reach root-level rm -rf and nspawn --machine; only the
      ## derived-name alphabet is allowed.
      check_name() {
        printf '%s' "$1" | grep -qE '^[a-zA-Z0-9-]+$' || die "invalid container name: $1"
      }

      read_container_config() {
        [ -f "$CONTAINER_CONFIG" ] ||
          die "no principal uid range declared: set nixcage.principalUidRange"
        # shellcheck disable=SC1090
        . "$CONTAINER_CONFIG"
      }

      ## Where allocations are recorded. The file was called role-uids while the
      ## factory lived here; renaming it in place keeps every number already
      ## handed out, which is the one property the store exists to have.
      uid_store() {
        local store="$STATE_DIR/principal-uids"
        if [ ! -f "$store" ] && [ -f "$STATE_DIR/role-uids" ]; then
          mv "$STATE_DIR/role-uids" "$store"
          echo "nixcage-container: moved the uid store to $store" >&2
        fi
        echo "$store"
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

      ## The subjects a cage has, declared by the host. Cage root is not one of
      ## them, so the block a principal is allocated is one wider than this.
      declared_subjects() { echo "''${PRINCIPAL_SUBJECTS:-}"; }

      ## What a new principal should be allocated. What an existing one has is
      ## read from the store instead, because a block is fixed when it is
      ## allocated and widening one in place would reach the uid after it.
      declared_block() {
        local subject count=1
        for subject in $(declared_subjects); do
          count=$((count + 1))
        done
        echo "$count"
      }

      ## A per-session rootfs skeleton is a few kilobytes; separate ones let
      ## concurrent sessions of the same project coexist because nspawn
      ## takes an exclusive lock on its directory tree.
      make_rootfs() {
        local root="$1" login="''${2:-}"
        ## nspawn refuses a rootfs without /usr ("doesn't look like it has
        ## an OS tree").
        mkdir -p "$root"/{etc,usr,tmp,root,workspace,nix,proc,sys,dev,run,var/empty}
        chmod 1777 "$root/tmp"
        echo 'NAME=nixcage' >"$root/etc/os-release"
        ## nspawn resolves every user but root by exec'ing getent inside the
        ## container, and this systemd is patched to look for it on Nix profile
        ## paths rather than at /usr/bin/getent or /bin/getent. None of them
        ## exists in a rootfs this size, so the exec fails, the helper returns
        ## nothing, and nspawn reports "Failed to resolve user" for a name the
        ## /etc/passwd written below carries.
        ##
        ## This is the search path that survives: a tmpfs is mounted over /run,
        ## and the lookup happens as root before the session drops to a subject.
        mkdir -p "$root/etc/profiles/per-user/root/bin"
        ln -sf ${pkgs.glibc.getent}/bin/getent \
          "$root/etc/profiles/per-user/root/bin/getent"
        cp /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true
        nixcage_principal_passwd "$login" "$(declared_subjects)" >"$root/etc/passwd" ||
          die "invalid principal or subject name"
        nixcage_principal_group "$(declared_subjects)" >"$root/etc/group" ||
          die "invalid subject name"
        cat >"$root/etc/nsswitch.conf" <<'EOF'
      passwd: files
      group: files
      hosts: files dns
      EOF
      }

      ## Build a session. Everything past the project bind is asked for by the
      ## caller: which uid the cage is mapped onto, what that uid is called
      ## inside it, where its home is kept, what else is mapped in, and what is
      ## in its environment. Nothing here knows why any of it was asked for.
      cmd_enter() {
        nixcage_enter_parse "$@" || exit 1
        set -- ''${NIXCAGE_ENTER_ARGV[@]+"''${NIXCAGE_ENTER_ARGV[@]}"}

        ## What the host declared, before anything reads it. A session resolves
        ## --subject against PRINCIPAL_SUBJECTS and writes an /etc/passwd entry
        ## per declared subject, and without this both are empty: every subject
        ## the host declared is refused as one that does not exist.
        read_container_config

        local name="''${1:-}" project="''${2:-}"
        [ -n "$name" ] && [ -n "$project" ] || die "$(usage)"
        shift 2
        check_name "$name"
        [ -d "$project" ] || die "project directory not found: $project"

        local auth_sock="$NIXCAGE_ENTER_AUTH_SOCK"
        local user="$NIXCAGE_ENTER_USER"
        local subject="$NIXCAGE_ENTER_SUBJECT"
        local home="$NIXCAGE_ENTER_HOME"
        local shell_name="$NIXCAGE_ENTER_SHELL"
        local uid="$NIXCAGE_ENTER_UID"
        local -a asked_binds=(''${NIXCAGE_ENTER_BINDS[@]+"''${NIXCAGE_ENTER_BINDS[@]}"})
        local -a asked_env=(''${NIXCAGE_ENTER_ENV[@]+"''${NIXCAGE_ENTER_ENV[@]}"})

        ## The name is checked here as well as where it is declared, because
        ## this is the last point before it becomes part of a flake reference
        ## inside the session.
        local -a shell_env=()
        if [ -n "$shell_name" ]; then
          nixcage_shell_name_ok "$shell_name" ||
            die "not a usable devShell name: $shell_name"
          shell_env=("--setenv=NIXCAGE_SHELL=$shell_name")
        fi

        ## An ordinary session is mapped onto the project owner: nix's libgit2
        ## refuses a repository owned by a different uid, and every project
        ## directory belongs to the invoking user (ADR-004). A caller that
        ## names a uid is entering on behalf of someone who owns the directory
        ## already, so the ownership check still passes.
        local owner_uid owner_gid
        if [ -n "$uid" ]; then
          owner_uid="$uid"
          owner_gid="$uid"
        else
          owner_uid="$(stat -c %u "$project")"
          owner_gid="$(stat -c %g "$project")"
        fi

        ## A linked git worktree keeps its git directory inside the primary
        ## repository, which the project bind does not cover; without these
        ## binds every git command in the session fails outright. The paths
        ## are bound at the spelling git itself recorded, so its own pointers
        ## resolve unchanged inside the container.
        local -a git_binds=()
        local git_dirs git_dir
        git_dirs="$(nixcage_git_binds "$project")" ||
          die "cannot resolve the git directory of $project"
        ## A linked worktree is also recorded by its own absolute path, inside
        ## the administrative directory git keeps for it. Tools that resolve a
        ## repository through libgit2 rather than through the .git file open
        ## that path directly -- nix's flake fetcher does, so without this bind
        ## every flake command in such a worktree fails on a directory that
        ## exists in the VM and not in the session. The project keeps its
        ## /workspace bind as well: that path is the one sessions are written
        ## against.
        if [ "$project" != /workspace ]; then
          git_binds+=("--bind=$project:$project")
        fi
        while IFS= read -r git_dir; do
          [ -n "$git_dir" ] || continue
          git_binds+=("--bind=$git_dir")
        done <<<"$git_dirs"

        ## A session runs as cage root unless the caller names one of the
        ## subjects the host declared. The offset decides both the uid inside
        ## the cage and the host uid its home must belong to, since ownership
        ## is not shifted on the way in.
        ## The cage maps the block this uid was allocated, never the width the
        ## host declares now: a principal allocated before a subject was
        ## declared sits directly against its neighbour, and mapping wider
        ## would put that neighbour inside this cage.
        local block
        block="$(nixcage_principal_size_at "$(uid_store)" "$owner_uid")" ||
          die "cannot resolve the block of uid $owner_uid"

        local subject_offset=0 session_home=/root
        if [ -n "$subject" ]; then
          subject_offset="$(nixcage_principal_subject_offset "$subject" "$(declared_subjects)")" ||
            die "no such subject: $subject"
          [ "$subject_offset" -lt "$block" ] ||
            die "uid $owner_uid holds a block of $block; it has no subject $subject"
          session_home="/home/$subject"
        fi
        local session_uid=$((owner_uid + subject_offset))
        local session_gid=$((owner_gid + subject_offset))
        local -a session_user=()
        [ -n "$subject" ] && session_user=("--user=$subject")

        local cdir="$STATE_DIR/containers/$name"
        [ -n "$home" ] || home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"
        ## The home holds whatever the session writes there, so it is private
        ## to the subject running. If its contents belong to someone else the
        ## whole tree is re-owned rather than left unusable: a principal's uid
        ## can change when nixcage state is lost and reallocated, and a home
        ## the session cannot write fails far from that cause, as a read-only
        ## database deep inside a flake evaluation.
        if [ "$(stat -c %u "$home")" != "$session_uid" ] ||
          [ -n "$(find "$home" ! -uid "$session_uid" -print -quit 2>/dev/null)" ]; then
          chown -R "$session_uid:$session_gid" "$home"
        fi
        chmod 700 "$home"

        local rootfs="$cdir/session-$$"
        make_rootfs "$rootfs" "$user"
        ## The home is bound over this, so what it holds never shows; it has
        ## to exist for the bind to land on something.
        mkdir -p "$rootfs$session_home"
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

        ## Git identity, rendered by the platform module from nixcage.git.
        ## Absent when the user declared none, in which case git behaves as
        ## it does anywhere else without an identity. A caller entering as
        ## someone else binds its own file over this one.
        if [ -f /etc/nixcage/gitconfig ]; then
          cp /etc/nixcage/gitconfig "$rootfs/etc/gitconfig"
        fi

        ## Commits are signed through the invoking user's agent: the socket
        ## is forwarded in, no key material is. The container is mapped onto
        ## the project owner, so the socket has to be reachable by that uid
        ## rather than by whoever forwarded it.
        local -a agent_bind=()
        if [ -n "$auth_sock" ]; then
          if [ -S "$auth_sock" ]; then
            chown "$session_uid:$session_gid" "$auth_sock"
            : >"$rootfs/run/ssh-agent.sock"
            agent_bind=(
              "--bind=$auth_sock:/run/ssh-agent.sock"
              "--setenv=SSH_AUTH_SOCK=/run/ssh-agent.sock"
            )
          else
            echo "nixcage-container: no agent socket at $auth_sock; commits cannot be signed" >&2
          fi
        fi

        write_secret_env "$rootfs/etc/nixcage-env"
        ## Everything the skeleton contains was created by root and would
        ## otherwise appear as an unmapped nobody inside the container.
        chown -R "$owner_uid:$owner_gid" "$rootfs"

        systemd-nspawn --quiet --register=no \
          --directory="$rootfs" \
          --machine="$name" \
          --private-users="$owner_uid:$block" \
          --private-users-ownership=off \
          --bind-ro=/nix/store \
          --bind-ro=/nix/var/nix/db \
          --bind=/nix/var/nix/daemon-socket \
          --bind="$project:/workspace" \
          --bind="$home:$session_home" \
          ''${git_binds[@]+"''${git_binds[@]}"} \
          ''${agent_bind[@]+"''${agent_bind[@]}"} \
          ''${asked_binds[@]+"''${asked_binds[@]}"} \
          --chdir=/workspace \
          ''${session_user[@]+"''${session_user[@]}"} \
          --setenv=HOME="$session_home" \
          --setenv=PATH="$PROFILE/bin" \
          --setenv=NIX_REMOTE=daemon \
          --setenv=NIX_CONFIG='experimental-features = nix-command flakes' \
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          --setenv=NIXCAGE_DIRENVRC="${pkgs.nix-direnv}/share/nix-direnv/direnvrc" \
          ''${shell_env[@]+"''${shell_env[@]}"} \
          ''${asked_env[@]+"''${asked_env[@]}"} \
          --setenv=TERM="''${TERM:-xterm}" \
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
      }

      ## The uid of a named principal, allocated on first use and never
      ## reissued. What a principal is stays the caller's: nixcage only
      ## promises that one name always answers with one number.
      cmd_uid() {
        local principal="''${1:-}" subject="''${2:-}"
        [ -n "$principal" ] || die "usage: nixcage-container uid <principal> [<subject>]"
        read_container_config

        ## Allocating is what makes a subject's number answerable, so it
        ## happens either way: a caller asking for a subject of a principal
        ## that has never been seen gets that principal allocated first.
        local base
        base="$(nixcage_principal_uid "$(uid_store)" \
          "''${PRINCIPAL_UID_BASE:?}" "''${PRINCIPAL_UID_SIZE:?}" \
          "$principal" "$(declared_block)")" || exit 1

        if [ -z "$subject" ]; then
          echo "$base"
          return 0
        fi

        ## A caller names a subject and nixcage names the number, so the
        ## offset is resolved here rather than added by whoever asked.
        local offset
        offset="$(nixcage_principal_subject_offset "$subject" "$(declared_subjects)")" ||
          die "no such subject: $subject"
        nixcage_principal_subject_uid "$(uid_store)" "$principal" "$offset" ||
          die "$principal has no subject $subject"
      }

      ## Give a path to a uid, bounded where it can be bounded. Whether that is
      ## a dataset or an ordinary directory is nixcage's decision, and the
      ## caller is not told which it got (ADR-017).
      cmd_storage() {
        local sub="''${1:-}"
        shift || true
        case "$sub" in
        ensure)
          local path="''${1:-}" uid="''${2:-}" quota="''${3:-}"
          [ -n "$path" ] && [ -n "$uid" ] ||
            die "usage: nixcage-container storage ensure <path> <uid> [quota]"
          nixcage_bind_path_ok "$path" || die "not a usable path: $path"
          printf '%s' "$uid" | grep -qE '^[0-9]+$' || die "not a uid: $uid"
          read_container_config
          nixcage_storage_ensure "$STATE_DIR" "''${STORAGE_DATASET:-}" \
            "$path" "$uid" "$quota"
          ;;
        *) die "usage: nixcage-container storage ensure <path> <uid> [quota]" ;;
        esac
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
      uid) cmd_uid "$@" ;;
      storage) cmd_storage "$@" ;;
      list) cmd_list ;;
      rm) cmd_rm "$@" ;;
      *) die "$(usage)" ;;
      esac
    '';
  };
  ## The git configuration a session sees, rendered from nixcage.git by
  ## whichever platform module is in use. Signing goes through the agent the
  ## CLI forwards, so no key is named here: with user.signingKey unset git
  ## calls gpg.ssh.defaultKeyCommand and signs with the first agent key.
  gitConfigText =
    git:
    ''
      [user]
        name = ${git.userName}
        email = ${git.userEmail}
    ''
    + pkgs.lib.optionalString git.signing.enable ''
      [gpg]
        format = ssh
      [gpg "ssh"]
        program = ${pkgs.openssh}/bin/ssh-keygen
        defaultKeyCommand = ssh-add -L
      [commit]
        gpgsign = true
      [tag]
        gpgsign = true
    '';
in
{
  profile = containerProfile;
  script = nixcageContainer;
  inherit gitConfigText;
}
