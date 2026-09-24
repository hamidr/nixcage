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
  ## What systemd-vmspawn runs a microVM with (ADR-019): qemu and virtiofsd,
  ## found on the script's path. Empty where the host builds no guest, and
  ## then a microvm session is refused before vmspawn is looked for.
  microvmPackages ? [ ],
}:
let
  ## Minimal userland for project containers. Containers hold no system of
  ## their own -- this profile plus the read-only store bind is everything.
  containerProfile = pkgs.buildEnv {
    name = "nixcage-container-profile";
    paths = with pkgs; [
      bashInteractive
      coreutils
      ## git pages its output for a person at a terminal; without a pager
      ## on PATH every git log there fails. A session with no terminal is
      ## told not to page instead (enter-args.sh).
      less
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
  ## The store paths a session's own line names besides the profile: what a
  ## session without the daemon has to see for that line to run at all
  ## (ADR-014). The environment selection is sourced by path; direnv reads
  ## its rc by path; a session on a private network sets its address and
  ## becomes its subject by path.
  sessionRoots = pkgs.lib.escapeShellArgs [
    "${./dev-shell.sh}"
    "${pkgs.nix-direnv}"
    "${pkgs.iproute2}"
    "${pkgs.util-linux}"
  ];

  nixcageContainer = pkgs.writeShellApplication {
    name = "nixcage-container";
    ## The sourced helpers are store paths, which shellcheck cannot follow from
    ## inside the build. They are real shell files and the dev shell lints them
    ## directly, so following them here would add nothing and the unfollowable
    ## source is what fails the build.
    excludeShellChecks = [ "SC1091" ];
    runtimeInputs = microvmPackages ++ (with pkgs; [
      coreutils
      systemd
      gnugrep
      ## The veth pair a bridge placement gets is made here (ADR-013), and
      ## its port is pinned and isolated here (ADR-015).
      iproute2
      nftables
      ## exec enters a running cage's namespaces and becomes a subject.
      util-linux
      ## The relay a session reaches the caller's agent through.
      socat
      ## The agent forward into a microVM is a shell around ssh, ended by
      ## its parent (ADR-019).
      procps
      ## Resolving a linked worktree's git directories, which the project bind
      ## does not cover.
      git
      ## The ownership check on a session's home walks it, so find has to be on
      ## the script's own PATH rather than only on the system's.
      findutils
      ## The closure a session without the daemon is bound is queried here,
      ## on the host, where the store's db is (ADR-014).
      nix
    ]);
    text = ''
      ## Sourced by store path: the file is a real shell file so shellcheck
      ## and the bats suite can read it, and the store is available here.
      . ${./git-worktree.sh}
      . ${./principal-uid.sh}
      . ${./storage.sh}
      . ${./bind.sh}
      . ${./store-closure.sh}
      . ${./substrate.sh}
      . ${./bounds.sh}
      . ${./declaration.sh}
      . ${./gitconfig.sh}
      . ${./enter-args.sh}
      . ${./dev-shell.sh}
      . ${./scope.sh}
      . ${./veth.sh}
      . ${./exec-cage.sh}
      . ${./vmspawn-args.sh}
      . ${./microvm-session.sh}

      ## scope.sh names the same directory for the records it reads; one
      ## spelling, taken from there.
      STATE_DIR="$NIXCAGE_STATE_DIR"
      ## What the platform module rendered: one file, versioned, holding
      ## every setting a session or the CLI reads. Absent on a host that
      ## declared nothing, and on one whose nixcage is older than this script,
      ## which is what the two names beneath it are for.
      DECLARATION=/etc/nixcage/declaration
      LEGACY_CONFIG=/etc/nixcage/config
      LEGACY_CONTAINER=/etc/nixcage/container
      ## Resolve the /etc symlink to its store path: the container has its
      ## own /etc, but the store bind makes store paths valid inside. Absent
      ## where nothing rendered /etc/nixcage (ADR-023), and then the session
      ## names the layer it was built from with --profile.
      PROFILE_LINK=/etc/nixcage/profile
      LEGACY_SECRET_ENV=/etc/nixcage/secret-env
      ## What a vsock address resolves through (ADR-019 decision 6). systemd
      ## ships the snippet and NixOS includes it in ssh_config; naming it here
      ## makes exec and the agent forward work on a host that includes nothing
      ## (ADR-023).
      ## Read by microvm-session.sh, which is sourced by store path and so
      ## cannot be followed from here.
      # shellcheck disable=SC2034
      NIXCAGE_SSH_CONFIG=${pkgs.systemd}/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf

      die() { echo "nixcage-container: $*" >&2; exit 1; }

      ## One description of the interface, used by every path that has to
      ## print it. Two would drift, and this is the only thing a caller sees
      ## at run time telling it what nixcage exports.
      usage() { echo "usage: nixcage-container enter [--uid <n>] [--user <name>] [--subject <name>] [--home <path>] [--shell <name>] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--auth-sock <path>|--no-agent] [--network <bridge>:<addr>/<prefix>|ns:<path>] [--dns none|<addr>] [--no-nix-daemon] [--store-root <path>] [--memory <size>] [--cpus <n>] [--substrate nspawn|microvm] [--disk <size>] [--profile <path>] [--guest <path>] [--microvm-path <path>] [--git-name <name>] [--git-email <address>] [--print-argv] <name> <project> [cmd...] | uid <principal> [<subject>] | storage ensure <path> <uid> [quota] | status <name> | netns <name> | stop <name> | exec [--subject <name>] <name> [-- cmd...] | list [--json] | rm <name>"; }

      [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"

      ## Names reach root-level rm -rf and nspawn --machine; only the
      ## derived-name alphabet is allowed.
      check_name() {
        printf '%s' "$1" | grep -qE '^[a-zA-Z0-9-]+$' || die "invalid container name: $1"
      }

      ## What the host declared, or the undeclared answer to it (ADR-023).
      ## Absent is not a failure here: a session takes its uid from the
      ## project and its subjects from nobody, which is what an empty
      ## declaration already meant. The verbs whose promises need one refuse
      ## for themselves.
      read_container_config() {
        local status=0
        nixcage_declaration_read "$DECLARATION" || status=$?
        [ "$status" = 2 ] && die "this host's declaration is not one this nixcage reads"
        [ -n "''${NIXCAGE_DECLARED:-}" ] && return 0
        ## A module older than this script rendered the files this one
        ## replaced. Read rather than ignored: a host with workspace roots
        ## must not answer as a host with none (ADR-024 decision 7).
        nixcage_declaration_read_legacy "$LEGACY_CONFIG" "$LEGACY_CONTAINER"
        if [ -n "''${NIXCAGE_DECLARATION_LEGACY:-}" ]; then
          echo "nixcage-container: reading a declaration an older nixcage rendered; nixos-rebuild switch renders the current one" >&2
        fi
        return 0
      }

      ## The variable and secret pairs this host declared, from the field it
      ## declares them in or, on a host whose nixcage is older, the file they
      ## used to have of their own.
      secret_pairs() {
        if [ -n "''${NIXCAGE_DECLARATION_LEGACY:-}" ] && [ -f "$LEGACY_SECRET_ENV" ]; then
          local var secret
          while IFS='=' read -r var secret; do
            [ -n "$var" ] || continue
            printf '%s=%s\n' "$var" "$secret"
          done <"$LEGACY_SECRET_ENV"
          return 0
        fi
        nixcage_declaration_secret_pairs
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
        local pair var secret
        while IFS= read -r pair; do
          var="''${pair%%=*}" secret="''${pair#*=}"
          [ -n "$var" ] || continue
          if [ -r "/run/secrets/$secret" ]; then
            printf 'export %s=%q\n' "$var" "$(cat "/run/secrets/$secret")" >>"$out"
          else
            echo "nixcage-container: secret '$secret' for $var not found; skipping" >&2
          fi
        done < <(secret_pairs)
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
        ## /nix/store is a directory here so that a session without the
        ## daemon has an empty store to bind its closure onto (ADR-014).
        mkdir -p "$root"/{etc,usr,tmp,root,workspace,nix/store,proc,sys,dev,run,var/empty}
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
        ## What the cage resolves with is the parse's (ADR-016): a cage on
        ## a private network cannot reach the resolver the host's file names.
        nixcage_enter_resolv_conf /etc/resolv.conf "$root/etc/resolv.conf"
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
      ## The major version of the vmspawn on this path, or nothing.
      vmspawn_version() {
        command -v systemd-vmspawn >/dev/null 2>&1 || return 0
        systemd-vmspawn --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1
      }

      ## The microvm session (ADR-019), from the point enter has the cage's
      ## uid, home and record: reads cmd_enter's locals. The skeleton is the
      ## root share, owned by the cage's first uid because virtiofsd in its
      ## user namespace cannot create in a directory it does not own; the
      ## store is a read-only share whole (decision 5, wider than ADR-014's
      ## closure, and said so); every other share is the host uid as it is.
      ## What nspawn is handed as argv and environment goes into the
      ## credential the guest's session unit reads; secrets are resolved
      ## into it here, since no file of the rootfs reaches the guest.
      ## The guest marks itself ready in the home and leaves argv's status
      ## there; a watch stops a guest nobody heard from within the boot
      ## timeout, and the outcome is read from those files once vmspawn
      ## returns (microvm-session.sh).
      ## The environment a microvm session or exec gets: what the nspawn
      ## line sets by --setenv, with the secrets resolved here because no
      ## file of a rootfs reaches the guest. One word per line.
      ## microvm_env_words <session home> <login name or empty>
      microvm_env_words() {
        local session_home="$1" user="$2"
        printf -- '--setenv=%s\n' \
          HOME="$session_home" \
          PATH="$PROFILE/bin" \
          NIXCAGE_NO_NIX_DAEMON=1 \
          NIX_CONFIG='experimental-features = nix-command flakes' \
          NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          NIXCAGE_DIRENVRC="${pkgs.nix-direnv}/share/nix-direnv/direnvrc" \
          TERM="''${TERM:-xterm}"
        [ -z "$user" ] || printf -- '--setenv=%s\n' USER="$user" LOGNAME="$user"
        local pair var secret
        while IFS= read -r pair; do
          var="''${pair%%=*}" secret="''${pair#*=}"
          [ -n "$var" ] || continue
          if [ -r "/run/secrets/$secret" ]; then
            printf -- '--setenv=%s=%s\n' "$var" "$(cat "/run/secrets/$secret")"
          else
            echo "nixcage-container: secret '$secret' for $var not found; skipping" >&2
          fi
        done < <(secret_pairs)
      }

      enter_microvm() {
        local skeleton="$cdir/session-$$" credential="$cdir/session-$$.cred" stage="$cdir/session-$$.bind"
        mkdir -p "$skeleton"
        chown "$owner_uid:$owner_gid" "$skeleton"
        # shellcheck disable=SC2064
        trap "rm -rf '$skeleton' '$credential' '$stage'" EXIT
        trap 'exit 143' TERM HUP INT

        ## bash -c consumes its first argument as $0, so a placeholder
        ## precedes the command, as on nspawn.
        local shell_cmd=". ${./dev-shell.sh}; nixcage_enter_shell \"\$@\""
        set -- placeholder "$@"

        local -a env_words=()
        local word
        while IFS= read -r word; do
          env_words+=("$word")
        done < <(microvm_env_words "$session_home" "$user")
        local pager_tty="" pager
        if [ -t 0 ] && [ -t 1 ]; then pager_tty=1; fi
        while IFS= read -r pager; do
          env_words+=("--setenv=$pager")
        done < <(nixcage_enter_pager_env "$pager_tty")
        env_words+=(''${asked_env[@]+"''${asked_env[@]}"})

        ## The agent is forwarded as a socket over vsock ssh once the
        ## guest's sshd answers (decision 5); the credential tells the
        ## guest to wait for it, and the session finds it where an nspawn
        ## session does.
        local agent=""
        if [ -n "$auth_sock" ]; then
          if [ -S "$auth_sock" ]; then
            agent=1
            env_words+=(--setenv=SSH_AUTH_SOCK=/run/ssh-agent.sock)
          else
            echo "nixcage-container: no agent socket at $auth_sock; commits cannot be signed" >&2
          fi
        fi

        local tty=""
        if [ -t 0 ] && [ -t 1 ]; then tty=1; fi

        ## Only a directory crosses virtiofs. A regular file is staged as a
        ## copy, owner and mode kept, in a directory of its own beside the
        ## skeleton (never inside it: the skeleton is the guest's root), that
        ## directory is shared, and the guest binds the file onto its target
        ## from the credential (ADR-020). A socket or anything else is
        ## refused here rather than mounted as nothing.
        local -a bind_words=("--bind=$project:/workspace" "--bind=$home:$session_home")
        local -a all_binds=(''${git_binds[@]+"''${git_binds[@]}"} ''${asked_binds[@]+"''${asked_binds[@]}"})
        local bind src n dst mode
        while IFS=$'\t' read -r n src dst mode; do
          mkdir -p "$stage/$n"
          cp -p "$src" "$stage/$n/file" || die "could not stage $src for the microvm"
          bind_words+=("--bind-ro=$stage/$n:/run/nixcage/bind/$n")
          env_words+=("--file=$n:$mode:$dst")
        done < <(nixcage_vmspawn_file_binds ''${all_binds[@]+"''${all_binds[@]}"})
        for bind in ''${all_binds[@]+"''${all_binds[@]}"}; do
          src="''${bind#--bind=}"; src="''${src#--bind-ro=}"; src="''${src%%:*}"
          [ ! -f "$src" ] || continue
          [ -d "$src" ] || die "not a directory or a file, and nothing else crosses into a microvm: $src"
          bind_words+=("$(nixcage_vmspawn_bind_resolved "$bind")")
        done

        ## The image --disk asks for (decision 5): in a directory storage
        ## gave the session's uid under the state directory with the size
        ## as its quota (ADR-017), so it is owned and bounded like every
        ## other thing a cage keeps; sparse, made once, its size fixed then.
        ## Once the cage has one it is attached to every session, asked for
        ## or not: it is the cage's, as the home is.
        local disk=""
        if [ -f "$STATE_DIR/disks/$name/disk.img" ]; then
          disk="$STATE_DIR/disks/$name/disk.img"
        fi
        if [ -n "$NIXCAGE_ENTER_DISK" ]; then
          local disk_dir
          disk_dir="$(nixcage_storage_ensure "$STATE_DIR" "''${STORAGE_DATASET:-}" \
            "$STATE_DIR/disks/$name" "$session_uid" "$NIXCAGE_ENTER_DISK")" ||
            die "could not give $name a place for its disk"
          disk="$disk_dir/disk.img"
          if [ ! -f "$disk" ]; then
            truncate -s "$NIXCAGE_ENTER_DISK" "$disk" || die "could not make the disk image for $name"
            chown "$session_uid:$session_gid" "$disk"
          fi
        fi

        ## A placement (ADR-013, ADR-015): the port is a tap nixcage makes
        ## under its own name, on the bridge, pinned and isolated before
        ## the guest boots, and handed to qemu by name; the guest gives
        ## eth0 the address from the credential. Deleted with the skeleton,
        ## whichever way the session ends.
        local qemu_extra=""
        if [ -n "$network_bridge" ]; then
          nixcage_tap_make "$name" "$network_bridge" "$network_addr" ||
            die "could not make the tap for $name on $network_bridge"
          # shellcheck disable=SC2064
          trap "rm -rf '$skeleton' '$credential' '$stage'; nixcage_tap_delete '$name' 2>/dev/null" EXIT
          qemu_extra="$(nixcage_tap_qemu_words "$name" | paste -sd' ')"
        fi

        local cred
        # shellcheck disable=SC2153
        cred="$(nixcage_vmspawn_credential "$session_uid" "$session_gid" "$session_home" /workspace \
          "$tty" "$network_addr" "$agent" "$NIXCAGE_ENTER_DNS" "''${env_words[@]}" -- "$PROFILE/bin/bash" -c "$shell_cmd" "$@")"
        nixcage_vmspawn_credential_ok "$cred" || exit 1

        local -a vmspawn_words=()
        while IFS= read -r word; do
          vmspawn_words+=("$word")
        done < <(nixcage_vmspawn_args "$name" "$skeleton" "$MICROVM_GUEST" "$credential" \
          "$owner_uid" "$block" "$tty" "$NIXCAGE_ENTER_MEMORY" "$NIXCAGE_ENTER_CPUS" "$disk" "$qemu_extra" \
          "''${bind_words[@]}")
        if [ -n "$NIXCAGE_ENTER_PRINT_ARGV" ]; then
          printf '%s\n' "''${vmspawn_words[@]}"
          exit 0
        fi

        ## Refused before boot: a second enter on a running name would
        ## register a second machine under it (decision 7).
        case "$(nixcage_scope_status "$name" 2>/dev/null)" in
        running*) die "$name is running" ;;
        esac

        (umask 077 && printf '%s\n' "$cred" >"$credential") || die "could not write the session credential"
        ## What this session was asked by --setenv, for exec to give as well.
        nixcage_microvm_env_write "$cdir/session-env" ''${asked_env[@]+"''${asked_env[@]}"} ||
          die "could not keep the session environment for exec"
        local ready="$home/$NIXCAGE_MICROVM_READY" exit_file="$home/$NIXCAGE_MICROVM_EXIT"
        local stopped="$cdir/session-$$.stopped"
        rm -f "$ready" "$exit_file" "$stopped"
        # shellcheck disable=SC2064
        trap "rm -rf '$skeleton' '$credential' '$stage' '$stopped'; [ -z '$network_bridge' ] || nixcage_tap_delete '$name' 2>/dev/null" EXIT

        nixcage_microvm_watch "$ready" "$name" "$NIXCAGE_MICROVM_BOOT_TIMEOUT" "$stopped" &
        local watch=$! forward=""
        if [ -n "$agent" ]; then
          nixcage_agent_forward "$name" "$auth_sock" "$NIXCAGE_MICROVM_BOOT_TIMEOUT" 2>/dev/null &
          forward=$!
        fi
        "''${vmspawn_words[@]}" || true
        kill "$watch" 2>/dev/null || true
        wait "$watch" 2>/dev/null || true
        if [ -n "$forward" ]; then
          ## The forward is a shell around ssh: both go.
          pkill -P "$forward" 2>/dev/null || true
          kill "$forward" 2>/dev/null || true
          wait "$forward" 2>/dev/null || true
        fi

        local status
        status="$(nixcage_microvm_outcome "$ready" "$exit_file" "$stopped")"
        rm -f "$ready" "$exit_file"
        return "$status"
      }

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
        local network_bridge="$NIXCAGE_ENTER_NETWORK_BRIDGE"
        local network_addr="$NIXCAGE_ENTER_NETWORK_ADDR"
        local network_ns="$NIXCAGE_ENTER_NETWORK_NS"
        local no_nix_daemon="$NIXCAGE_ENTER_NO_NIX_DAEMON"
        ## What a session is built from is the host's answer where it gave
        ## one, so a declared host refuses the flags that would replace it
        ## rather than letting a caller choose what root runs here.
        local carried
        carried="$(nixcage_declaration_carried_flag "''${NIXCAGE_DECLARED:-}" \
          "$NIXCAGE_ENTER_PROFILE" "$NIXCAGE_ENTER_GUEST" \
          "''${#NIXCAGE_ENTER_MICROVM_PATHS[@]}")"
        [ -z "$carried" ] ||
          die "this host declared what a session is built from; $carried is for a host that declared none"

        ## The layer this session is built from: the one the host rendered,
        ## else the one the caller named. Resolved once here, because every
        ## path below spells it and a session with neither has nothing to run.
        PROFILE="$(readlink -f "$PROFILE_LINK" 2>/dev/null || true)"
        if [ -n "$NIXCAGE_ENTER_PROFILE" ]; then
          PROFILE="$NIXCAGE_ENTER_PROFILE"
        fi
        [ -n "$PROFILE" ] ||
          die "no container profile: pass --profile <path>, or import nixcage nixosModules.host"
        if [ -n "$NIXCAGE_ENTER_GUEST" ]; then
          MICROVM_GUEST="$NIXCAGE_ENTER_GUEST"
        fi
        ## vmspawn searches its own PATH for the hypervisor and for virtiofsd,
        ## so a session that named them puts them there. Appended, so a host
        ## that declared its own keeps answering with those.
        local microvm_path
        for microvm_path in ''${NIXCAGE_ENTER_MICROVM_PATHS[@]+"''${NIXCAGE_ENTER_MICROVM_PATHS[@]}"}; do
          PATH="$PATH:$microvm_path/bin"
        done
        export PATH

        local -a store_roots=(''${NIXCAGE_ENTER_STORE_ROOTS[@]+"''${NIXCAGE_ENTER_STORE_ROOTS[@]}"})
        ## What this host declared for this cage, ahead of what the session
        ## asked for: both are binds, and neither replaces the other. Two of
        ## them naming one destination is a refusal, because a session that
        ## quietly mounted something other than what it asked for would be
        ## the worse answer.
        ## Read before the loop rather than in a process substitution: a
        ## refusal inside one ends that subshell and leaves the loop happy.
        local declared_text declared_bind
        declared_text="$(nixcage_bind_declared "$project" "''${CAGE_BINDS:-}")" ||
          die "this host's declaration for $project names a bind nothing may be given"
        local -a declared_binds=()
        while IFS= read -r declared_bind; do
          [ -n "$declared_bind" ] || continue
          declared_binds+=("$declared_bind")
        done <<<"$declared_text"
        local -a asked_binds=(
          ''${declared_binds[@]+"''${declared_binds[@]}"}
          ''${NIXCAGE_ENTER_BINDS[@]+"''${NIXCAGE_ENTER_BINDS[@]}"}
        )
        nixcage_bind_clash ''${asked_binds[@]+"''${asked_binds[@]}"} || exit 1
        local -a asked_env=(''${NIXCAGE_ENTER_ENV[@]+"''${NIXCAGE_ENTER_ENV[@]}"})

        ## What the cage runs on (ADR-019), fixed by the host's declaration
        ## or the record of its first enter, else asked for, else the host's
        ## default. A flag against what is fixed is refused here, naming the
        ## winner. A microVM never has the daemon and cannot join a namespace
        ## or realise a devShell, so those are refused as the parse refuses
        ## them for the flag, since the record may make a session microvm
        ## without the flag.
        local substrate
        substrate="$(nixcage_substrate_resolve "$name" \
          "$(nixcage_substrate_declared "$project" "''${CAGE_SUBSTRATES:-}")" \
          "$(nixcage_scope_record_substrate "$name")" \
          "$NIXCAGE_ENTER_SUBSTRATE" "''${SUBSTRATE_DEFAULT:-}")" || exit 1
        if [ "$substrate" = microvm ]; then
          nixcage_microvm_refusal "''${HOST_PLATFORM:-linux}" "''${MICROVM_GUEST:-}" /dev/kvm \
            "$(vmspawn_version)" || exit 1
          [ -z "$shell_name" ] || die "--shell is not available on a microvm cage: it has no nix daemon"
          [ -z "$network_ns" ] || die "--network ns: is not available on a microvm cage: a VM has no namespace to join"
          no_nix_daemon=1
        elif [ -n "$NIXCAGE_ENTER_DISK" ]; then
          die "--disk needs a microvm cage"
        fi

        ## What the cage may use (ADR-022): the flag, then what the host
        ## declared for this cage, then the host's default. Empty stays
        ## empty, which is each substrate's own default and not nixcage's
        ## to choose. Resolved once for both substrates, and rendered by
        ## each of them alone: the scope's properties are the nspawn path's
        ## and the vmspawn line is the microVM's, because a MemoryMax= on a
        ## microVM's scope bounds qemu and kills the guest (ADR-019).
        local cage_bounds
        cage_bounds="$(nixcage_bounds_declared "$project" "''${CAGE_BOUNDS:-}")"
        ## Undeclared there is no host default to fall back on, so the machine
        ## is read instead of leaving the session with what the substrate
        ## boots by itself (ADR-023 decision 10). Announced, because a number
        ## nobody asked for and nobody declared is one a caller should see.
        local bounds_default="''${BOUNDS_DEFAULT:-}"
        if [ -z "''${NIXCAGE_DECLARED:-}" ]; then
          bounds_default="$(nixcage_bounds_machine)"
          if [ -n "$bounds_default" ]; then
            echo "nixcage-container: nothing was declared here, so this session gets half of this machine: $bounds_default" >&2
          fi
        fi
        NIXCAGE_ENTER_MEMORY="$(nixcage_bounds_resolve "$NIXCAGE_ENTER_MEMORY" \
          "$(nixcage_bounds_field 1 "$cage_bounds")" \
          "$(nixcage_bounds_field 1 "$bounds_default")")"
        NIXCAGE_ENTER_CPUS="$(nixcage_bounds_resolve "$NIXCAGE_ENTER_CPUS" \
          "$(nixcage_bounds_field 2 "$cage_bounds")" \
          "$(nixcage_bounds_field 2 "$bounds_default")")"

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
        ## A microVM session is never guest root, and the guest owns /root
        ## as root's, re-owning a home bound there (ADR-019 decision 5).
        if [ "$substrate" = microvm ] && [ -z "$subject" ]; then
          session_home=/home/nixcage
        fi
        local session_uid=$((owner_uid + subject_offset))
        local session_gid=$((owner_gid + subject_offset))
        local -a session_user=()
        [ -n "$subject" ] && session_user=("--user=$subject")


        local cdir="$STATE_DIR/containers/$name" asked_home="$home"
        [ -n "$home" ] || home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"
        ## What this session was given, for list --json to show while it
        ## runs and after (ADR-017). Written before anything else of the
        ## session exists, so a session that dies on the way still left it.
        ## Which nixcage wrote this, and whether it had a declaration to read
        ## (ADR-023 decision 4). $0 is how this script was reached: its store
        ## path when a session ran it from the store, and the path a module
        ## installed it at otherwise, which is the difference the field is
        ## recorded for.
        nixcage_scope_record_write "$name" "$owner_uid" "$subject" "$network_bridge" "$network_addr" "$network_ns" "$substrate" \
          "--writer=$0" "--declared=''${NIXCAGE_DECLARED:-}" \
          ''${declared_binds[@]+"''${declared_binds[@]/#/--declared-bind=}"} \
          ''${asked_home:+"--home=$asked_home"} \
          ''${NIXCAGE_ENTER_PROFILE:+"--profile=$NIXCAGE_ENTER_PROFILE"} \
          ''${store_roots[@]+"''${store_roots[@]}"} ||
          die "could not record the placement of $name"
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

        if [ "$substrate" = microvm ]; then
          enter_microvm "$@"
          exit $?
        fi

        local rootfs="$cdir/session-$$"
        make_rootfs "$rootfs" "$user"
        ## The home is bound over this, so what it holds never shows; it has
        ## to exist for the bind to land on something.
        mkdir -p "$rootfs$session_home"
        ## Expand now: locals are out of scope when the EXIT trap fires.
        # shellcheck disable=SC2064
        trap "rm -rf '$rootfs'" EXIT
        ## A signal that is not trapped ends bash without the EXIT trap, and
        ## a supervisor stopping a session sends one: the rootfs and the veth
        ## below stayed, and the next session for the name could not start.
        trap 'exit 143' TERM HUP INT

        ## The environment is chosen inside the container, where the project
        ## is actually bound; the library is referenced by store path because
        ## the store is bound read-only there. bash -c consumes the first
        ## argument as $0, so a placeholder always precedes the user command.
        local shell_cmd=". /etc/nixcage-env 2>/dev/null || true; \
          . ${./dev-shell.sh}; \
          nixcage_enter_shell \"\$@\""
        set -- placeholder "$@"

        ## A cage on a private network has one veth, on the bridge the
        ## caller named, and no other interface. nspawn makes the veth and
        ## retains CAP_NET_ADMIN inside, and nothing else assigns the
        ## address: the session's first process is cage root long enough to
        ## set it on host0, then becomes the subject. --user would have made
        ## it the subject before host0 existed, so the switch is ours here.
        ## The inner bash -c consumes its first argument as $0 exactly as
        ## the outer one does, so the placeholder is given again; without it
        ## the command's first word was eaten and "--mode" reached exec.
        ##
        ## A session joining a running cage's namespace has nothing to set:
        ## the cage that owns it did, so the switch to the subject is
        ## nspawn's own --user as in an ordinary session.
        local -a network_args=() session_cmd_env=()
        if [ -n "$network_ns" ]; then
          network_args=("--network-namespace-path=$network_ns")
        elif [ -n "$network_bridge" ]; then
          ## The pair is nixcage's (ADR-013): made here, its host end on
          ## the bridge under a name that fits any cage name, pinned to the
          ## placement's address and isolated from every other port
          ## (ADR-015), its cage end handed to nspawn to rename host0.
          ## Deleted with the rootfs, pin first, whichever way the session
          ## ends.
          nixcage_veth_make "$name" "$network_bridge" "$network_addr" ||
            die "could not make the veth pair for $name on $network_bridge"
          # shellcheck disable=SC2064
          trap "rm -rf '$rootfs'; nixcage_veth_delete '$name' 2>/dev/null" EXIT
          network_args=("$(nixcage_veth_nspawn_arg "$name")")
          session_user=()
          session_cmd_env=("--setenv=NIXCAGE_SESSION_CMD=$shell_cmd")
          local become=""
          if [ -n "$subject" ]; then
            become="export USER=$subject LOGNAME=$subject; \
              exec ${pkgs.util-linux}/bin/setpriv \
                --reuid=$subject_offset --regid=$subject_offset --clear-groups --"
          else
            become="exec"
          fi
          shell_cmd="${pkgs.iproute2}/bin/ip addr add $network_addr dev host0 && \
            ${pkgs.iproute2}/bin/ip link set host0 up && \
            $become $PROFILE/bin/bash -c \"\$NIXCAGE_SESSION_CMD\" placeholder \"\$@\""
        fi

        ## The daemon socket is what lets nix inside a session build and
        ## fetch. A caller that asks for none gets a session where nix cannot
        ## reach a store at all, which is the point.
        local -a daemon_args=(
          --bind=/nix/var/nix/daemon-socket
          --setenv=NIX_REMOTE=daemon
        )
        ## Told to the session as well, so the environment selection inside
        ## skips the flake probe it could not run (dev-shell.sh).
        [ -n "$no_nix_daemon" ] && daemon_args=(--setenv=NIXCAGE_NO_NIX_DAEMON=1)

        ## What of the store the session sees (ADR-014). With the daemon,
        ## all of it: the daemon adds paths while the session runs and the
        ## session has to see them. Without it, the closure of what it was
        ## handed and nothing else: the base profile, the store paths this
        ## line names, and the roots the caller realised elsewhere. The
        ## query is one, on the host, before nspawn runs; a root the store
        ## does not hold ends the session here with nix's message.
        local -a store_args=(
          --bind-ro=/nix/store
          --bind-ro=/nix/var/nix/db
        )
        if [ -n "$no_nix_daemon" ]; then
          local store_binds
          store_binds="$(nixcage_store_bind_args "$PROFILE" ${sessionRoots} \
            ''${store_roots[@]+"''${store_roots[@]}"})" ||
            die "could not close over the session's store roots"
          mapfile -t store_args <<<"$store_binds"
        fi

        ## Git identity: the one the session named, else the one this host
        ## declared, rendered here either way so both produce one file from
        ## one renderer. A caller entering as someone else binds its own file
        ## over this one, and a host that declared none leaves git to say
        ## "who are you" as it does anywhere else.
        local git_name="''${NIXCAGE_ENTER_GIT_NAME:-''${GIT_USER_NAME:-}}"
        local git_email="''${NIXCAGE_ENTER_GIT_EMAIL:-''${GIT_USER_EMAIL:-}}"
        nixcage_gitconfig_text "$git_name" "$git_email" "''${GIT_SIGNING:-}" \
          ${pkgs.openssh}/bin/ssh-keygen >"$rootfs/etc/gitconfig"
        if [ -f /etc/nixcage/gitconfig ] && [ ! -s "$rootfs/etc/gitconfig" ]; then
          ## A module older than this script rendered the file itself.
          cp /etc/nixcage/gitconfig "$rootfs/etc/gitconfig"
        fi

        ## Commits are signed through the invoking user's agent: the socket
        ## is forwarded in, no key material is. The session's uid is often
        ## not the caller's (a principal's block, ADR-010), so what it gets
        ## is a relay of its own, owned by that uid, which root connects to
        ## the caller's socket. The caller's socket keeps its owner: taking
        ## it cut its owner off from their own agent and left it with the
        ## session's uid after the session ended. The relay dies with this
        ## script, however it ends.
        local -a agent_bind=()
        local agent_relay=""
        if [ -n "$auth_sock" ]; then
          if [ -S "$auth_sock" ]; then
            agent_relay="$cdir/agent-$$.sock"
            rm -f "$agent_relay"
            setpriv --pdeathsig TERM -- socat \
              "UNIX-LISTEN:$agent_relay,fork,mode=600,user=$session_uid,group=$session_gid" \
              "UNIX-CONNECT:$auth_sock" 2>/dev/null &
            local waited=0
            until [ -S "$agent_relay" ] || [ "$waited" -ge 50 ]; do
              sleep 0.1
              waited=$((waited + 1))
            done
            [ -S "$agent_relay" ] || die "could not relay the agent at $auth_sock"
            : >"$rootfs/run/ssh-agent.sock"
            agent_bind=(
              "--bind=$agent_relay:/run/ssh-agent.sock"
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

        ## Bounds are properties of the scope nspawn allocates for the cage
        ## (ADR-012); with none asked, the cage is bounded by the machine.
        local -a property_args=()
        local property_line
        while IFS= read -r property_line; do
          [ -n "$property_line" ] || continue
          property_args+=("$property_line")
        done < <(nixcage_enter_property_args)

        ## The line as it would run, held as an array so that --print-argv
        ## can print it one word per line and run nothing: a dependant asserts
        ## what nixcage makes of its flags against this, with no cage.
        ## The console is read-only without a caller terminal (nspawn's
        ## default), so nothing in the session may wait on a pager.
        local -a pager_env=()
        local pager_tty="" pager
        if [ -t 0 ] && [ -t 1 ]; then pager_tty=1; fi
        while IFS= read -r pager; do
          pager_env+=("--setenv=$pager")
        done < <(nixcage_enter_pager_env "$pager_tty")

        local -a nspawn_args=(
          --quiet --register=no
          --directory="$rootfs"
          --machine="$name"
          ''${property_args[@]+"''${property_args[@]}"}
          --private-users="$owner_uid:$block"
          --private-users-ownership=off
          "''${store_args[@]}"
          ''${daemon_args[@]+"''${daemon_args[@]}"}
          ''${network_args[@]+"''${network_args[@]}"}
          --bind="$project:/workspace"
          --bind="$home:$session_home"
          ''${git_binds[@]+"''${git_binds[@]}"}
          ''${agent_bind[@]+"''${agent_bind[@]}"}
          ''${asked_binds[@]+"''${asked_binds[@]}"}
          --chdir=/workspace
          ''${session_user[@]+"''${session_user[@]}"}
          --setenv=HOME="$session_home"
          --setenv=PATH="$PROFILE/bin"
          ''${session_cmd_env[@]+"''${session_cmd_env[@]}"}
          --setenv=NIX_CONFIG='experimental-features = nix-command flakes'
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
          --setenv=NIXCAGE_DIRENVRC="${pkgs.nix-direnv}/share/nix-direnv/direnvrc"
          ''${shell_env[@]+"''${shell_env[@]}"}
          ''${pager_env[@]+"''${pager_env[@]}"}
          ''${asked_env[@]+"''${asked_env[@]}"}
          --setenv=TERM="''${TERM:-xterm}"
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
        )
        if [ -n "$NIXCAGE_ENTER_PRINT_ARGV" ]; then
          printf '%s\n' systemd-nspawn "''${nspawn_args[@]}"
          [ -z "$agent_relay" ] || rm -f "$agent_relay"
          exit 0
        fi
        local status=0
        systemd-nspawn "''${nspawn_args[@]}" || status=$?
        [ -z "$agent_relay" ] || rm -f "$agent_relay"
        return "$status"
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
        ## A number invented here would be handed out against the same state
        ## directory a declared host writes, and ADR-009 promises a principal's
        ## number is never reissued.
        [ -n "''${PRINCIPAL_UID_BASE:-}" ] ||
          die "$(nixcage_declaration_refusal uid nixcage.principalUidRange)"

        local base
        base="$(nixcage_principal_uid "$(uid_store)" \
          "''${PRINCIPAL_UID_BASE}" "''${PRINCIPAL_UID_SIZE:?}" \
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
          ## Where there is a pool this is a dataset and where there is not it
          ## is a directory (ADR-017), but which of the two is the host's
          ## answer to give. Undeclared there is no answer, not a default.
          [ -n "''${NIXCAGE_DECLARED:-}" ] ||
            die "$(nixcage_declaration_refusal 'storage ensure' nixcage.storage.dataset)"
          nixcage_storage_ensure "$STATE_DIR" "''${STORAGE_DATASET:-}" \
            "$path" "$uid" "$quota"
          ;;
        *) die "usage: nixcage-container storage ensure <path> <uid> [quota]" ;;
        esac
      }

      ## The verbs over a running cage, read from its scope (ADR-012).
      cmd_status() {
        local name="''${1:-}"
        [ -n "$name" ] || die "usage: nixcage-container status <name>"
        check_name "$name"
        nixcage_scope_status "$name"
      }

      cmd_netns() {
        local name="''${1:-}"
        [ -n "$name" ] || die "usage: nixcage-container netns <name>"
        check_name "$name"
        nixcage_scope_netns "$name"
      }

      cmd_stop() {
        local name="''${1:-}"
        [ -n "$name" ] || die "usage: nixcage-container stop <name>"
        check_name "$name"
        nixcage_scope_stop "$name"
      }

      ## A command inside a running cage, in every namespace of its leader,
      ## as cage root or as one of the host's declared subjects (ADR-012).
      cmd_exec() {
        local subject="" name="" offset=""
        if [ "''${1:-}" = "--subject" ]; then
          subject="''${2:-}"
          shift 2 || die "usage: nixcage-container exec [--subject <name>] <name> [-- cmd...]"
        fi
        name="''${1:-}"
        [ -n "$name" ] || die "usage: nixcage-container exec [--subject <name>] <name> [-- cmd...]"
        shift
        check_name "$name"
        local leader
        leader="$(nixcage_scope_leader "$name")" || die "$name is not running"
        if [ -n "$subject" ]; then
          read_container_config
          offset="$(nixcage_principal_subject_offset "$subject" "$(declared_subjects)")" ||
            die "no such subject: $subject"
        fi
        if [ "$(nixcage_scope_record_substrate "$name")" = microvm ]; then
          exec_microvm "$name" "$subject" "$offset" "$@"
        fi
        local -a words=()
        local word
        while IFS= read -r word; do
          words+=("$word")
        done < <(NIXCAGE_EXEC_ENV=${pkgs.coreutils}/bin/env NIXCAGE_EXEC_SETPRIV=${pkgs.util-linux}/bin/setpriv \
          nixcage_exec_words "$leader" "$offset" -- "$@")
        exec "''${words[@]}"
      }

      ## exec on a microvm cage (ADR-019 decision 6): ssh over vsock to the
      ## guest's root, becoming the session's uid there. There is no leader
      ## whose environment could be read, so the command gets what a session
      ## is given, secrets resolved now, and what the last enter was asked
      ## by --setenv, kept beside the record for this. The uid is the record's
      ## plus the subject's offset; the gid is the home's, which enter gave
      ## the last session's, so an exec as another subject than the last
      ## session's carries that session's group.
      ## exec_microvm <name> <subject> <offset> [cmd...]
      exec_microvm() {
        local name="$1" subject="$2" offset="''${3:-0}"
        shift 3
        read_container_config
        local key address
        { read -r key && read -r address; } < <(nixcage_microvm_ssh_target "$name") || exit 1
        local record uid
        record="$(<"$STATE_DIR/containers/$name/placement")"
        [[ "$record" =~ \"uid\":([0-9]+) ]] || die "$name has no uid in its record"
        uid=$((BASH_REMATCH[1] + offset))
        ## PATH comes from the layer the session was built from: the one
        ## enter was named, which only the record still knows, else the
        ## host's.
        PROFILE="$(nixcage_scope_record_profile "$name")"
        [ -n "$PROFILE" ] || PROFILE="$(readlink -f "$PROFILE_LINK" 2>/dev/null || true)"
        [ -n "$PROFILE" ] ||
          die "$name has no layer: its record names none and there is no $PROFILE_LINK"
        ## The home is the record's when the session named one (ADR-017),
        ## else the default under the state directory.
        local gid home
        home="$(nixcage_scope_record_home "$name")"
        [ -n "$home" ] || home="$STATE_DIR/homes/$name"
        gid="$(stat -c %g "$home")" || die "$name has no home at $home"
        local session_home="/home/''${subject:-nixcage}"
        local tty=""
        if [ -t 0 ] && [ -t 1 ]; then tty=1; fi
        local -a env_words=() words=()
        local word
        while IFS= read -r word; do
          env_words+=("$word")
        done < <(microvm_env_words "$session_home" "")
        ## Where the session's forwarded agent is, when there is one.
        env_words+=(--setenv=SSH_AUTH_SOCK=/run/ssh-agent.sock)
        local -a asked=()
        mapfile -d "" -t asked < <(nixcage_microvm_env_read "$STATE_DIR/containers/$name/session-env")
        env_words+=(''${asked[@]+"''${asked[@]}"})
        while IFS= read -r word; do
          env_words+=("$word")
        done < <(nixcage_microvm_exec_path_word "$PROFILE" ''${asked[@]+"''${asked[@]}"})
        local -a probe=()
        while IFS= read -r word; do
          probe+=("$word")
        done < <(NIXCAGE_EXEC_ENV=${pkgs.coreutils}/bin/env NIXCAGE_EXEC_SETPRIV=${pkgs.util-linux}/bin/setpriv \
          nixcage_exec_microvm_words "$key" "$address" "$uid" "$gid" "" -- true)
        nixcage_microvm_await "$NIXCAGE_MICROVM_BOOT_TIMEOUT" "''${probe[@]}" || exit 1
        while IFS= read -r word; do
          words+=("$word")
        done < <(NIXCAGE_EXEC_ENV=${pkgs.coreutils}/bin/env NIXCAGE_EXEC_SETPRIV=${pkgs.util-linux}/bin/setpriv \
          nixcage_exec_microvm_words "$key" "$address" "$uid" "$gid" "$tty" "''${env_words[@]}" -- "$@")
        exec "''${words[@]}"
      }

      ## Names, or with --json what each was given and whether it runs
      ## (ADR-017).
      cmd_list() {
        case "''${1:-}" in
        --json) nixcage_scope_list_json ;;
        "")
          [ -d "$STATE_DIR/containers" ] || return 0
          ls -1 "$STATE_DIR/containers"
          ;;
        *) die "usage: nixcage-container list [--json]" ;;
        esac
      }

      cmd_rm() {
        local name="$1"
        check_name "$name"
        rm -rf "$STATE_DIR/containers/''${name:?}" "$STATE_DIR/homes/''${name:?}" "$STATE_DIR/disks/''${name:?}"
      }

      cmd="''${1:-}"
      shift || true
      case "$cmd" in
      enter) cmd_enter "$@" ;;
      uid) cmd_uid "$@" ;;
      storage) cmd_storage "$@" ;;
      status) cmd_status "$@" ;;
      netns) cmd_netns "$@" ;;
      stop) cmd_stop "$@" ;;
      exec) cmd_exec "$@" ;;
      list) cmd_list "$@" ;;
      rm) cmd_rm "$@" ;;
      *) die "$(usage)" ;;
      esac
    '';
  };
in
{
  profile = containerProfile;
  script = nixcageContainer;
}
