# shellcheck shell=bash
## The options `enter` is parameterised with (ADR-009).
##
## This is nixcage's exported interface, so it is a shell file rather than a
## loop inside the Nix string that builds nixcage-container: the suite sources
## this and drives it directly, and an interface nothing can drive is one that
## breaks at a dependant's run time instead of at ours.
##
## Sourced by store path into nixcage-container, beside bind.sh, whose checks
## every asked-for bind and variable goes through, and store-closure.sh,
## whose check every store root goes through.

## What a parse produced. Globals rather than a printed record because two of
## them are arrays, and a session command may hold newlines, spaces and
## anything else a caller wants to run.
##
## Every one of them is read by whoever called the parse, which shellcheck
## cannot see from inside this file.
# shellcheck disable=SC2034
nixcage_enter_reset() {
	NIXCAGE_ENTER_UID=""
	NIXCAGE_ENTER_USER=""
	NIXCAGE_ENTER_SUBJECT=""
	NIXCAGE_ENTER_HOME=""
	NIXCAGE_ENTER_SHELL=""
	NIXCAGE_ENTER_AUTH_SOCK=""
	NIXCAGE_ENTER_NO_AGENT=""
	NIXCAGE_ENTER_NETWORK_BRIDGE=""
	NIXCAGE_ENTER_NETWORK_ADDR=""
	NIXCAGE_ENTER_NETWORK_NS=""
	NIXCAGE_ENTER_NO_NIX_DAEMON=""
	NIXCAGE_ENTER_MEMORY=""
	NIXCAGE_ENTER_CPUS=""
	NIXCAGE_ENTER_PRINT_ARGV=""
	NIXCAGE_ENTER_BINDS=()
	NIXCAGE_ENTER_ENV=()
	NIXCAGE_ENTER_STORE_ROOTS=()
	NIXCAGE_ENTER_ARGV=()
}

## Consume the options and leave everything from the first non-option word on
## in NIXCAGE_ENTER_ARGV. Options precede the positional arguments so a session
## command can still be anything at all, including something spelt like a flag
## of ours.
nixcage_enter_parse() {
	nixcage_enter_reset

	local arg
	while [ $# -gt 0 ]; do
		case "$1" in
		--auth-sock)
			NIXCAGE_ENTER_AUTH_SOCK="${2:-}"
			shift 2 || return 1
			;;
		--no-agent)
			NIXCAGE_ENTER_NO_AGENT=1
			shift
			;;
		--uid)
			NIXCAGE_ENTER_UID="${2:-}"
			shift 2 || return 1
			;;
		--user)
			NIXCAGE_ENTER_USER="${2:-}"
			shift 2 || return 1
			;;
		--subject)
			NIXCAGE_ENTER_SUBJECT="${2:-}"
			shift 2 || return 1
			;;
		--home)
			NIXCAGE_ENTER_HOME="${2:-}"
			shift 2 || return 1
			;;
		--shell)
			NIXCAGE_ENTER_SHELL="${2:-}"
			shift 2 || return 1
			;;
		--network)
			nixcage_enter_network_arg "${2:-}" || return 1
			shift 2 || return 1
			;;
		--no-nix-daemon)
			NIXCAGE_ENTER_NO_NIX_DAEMON=1
			shift
			;;
		--memory)
			NIXCAGE_ENTER_MEMORY="${2:-}"
			shift 2 || return 1
			;;
		--cpus)
			NIXCAGE_ENTER_CPUS="${2:-}"
			shift 2 || return 1
			;;
		--print-argv)
			NIXCAGE_ENTER_PRINT_ARGV=1
			shift
			;;
		--bind)
			arg="$(nixcage_bind_arg --bind "${2:-}")" || return 1
			NIXCAGE_ENTER_BINDS+=("$arg")
			shift 2 || return 1
			;;
		--bind-ro)
			arg="$(nixcage_bind_arg --bind-ro "${2:-}")" || return 1
			NIXCAGE_ENTER_BINDS+=("$arg")
			shift 2 || return 1
			;;
		--setenv)
			arg="$(nixcage_setenv_arg "${2:-}")" || return 1
			NIXCAGE_ENTER_ENV+=("$arg")
			shift 2 || return 1
			;;
		--store-root)
			## A path the caller realised and wants a session without the
			## daemon to see with its closure (ADR-014). Held to the store's
			## own spelling here; whether the store holds it is the query's
			## answer, at the session.
			if ! nixcage_store_root_ok "${2:-}"; then
				echo "nixcage: not a store path: ${2:-}" >&2
				return 1
			fi
			NIXCAGE_ENTER_STORE_ROOTS+=("$2")
			shift 2 || return 1
			;;
		*) break ;;
		esac
	done

	NIXCAGE_ENTER_ARGV=("$@")

	## Refused rather than resolved: a silent preference would decide a
	## security property by argument order (ADR-008).
	if [ -n "$NIXCAGE_ENTER_AUTH_SOCK" ] && [ -n "$NIXCAGE_ENTER_NO_AGENT" ]; then
		echo "nixcage: --auth-sock and --no-agent are mutually exclusive" >&2
		return 1
	fi

	## A devShell is realised by nix inside the session, and nix inside the
	## session reaches the store through the daemon. Refused for the same
	## reason the agent pair is: the alternative is a session that fails at
	## its first command with an error about a socket nobody mentioned.
	if [ -n "$NIXCAGE_ENTER_SHELL" ] && [ -n "$NIXCAGE_ENTER_NO_NIX_DAEMON" ]; then
		echo "nixcage: --shell and --no-nix-daemon are mutually exclusive" >&2
		return 1
	fi

	if [ -n "$NIXCAGE_ENTER_UID" ] &&
		! [[ "$NIXCAGE_ENTER_UID" =~ ^[0-9]+$ ]]; then
		echo "nixcage: not a uid: $NIXCAGE_ENTER_UID" >&2
		return 1
	fi

	## A subject is one of the names the host declared, and it reaches
	## /etc/passwd and nspawn's --user, so it is held to the same alphabet a
	## principal is. Which offset it maps to is decided where the declaration
	## is read, not here.
	if [ -n "$NIXCAGE_ENTER_SUBJECT" ] &&
		! [[ "$NIXCAGE_ENTER_SUBJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
		echo "nixcage: not a subject name: $NIXCAGE_ENTER_SUBJECT" >&2
		return 1
	fi

	## Bounds become properties of the cage's scope (ADR-012), in the forms
	## systemd reads: a size with a unit letter, a count of whole cpus.
	if [ -n "$NIXCAGE_ENTER_MEMORY" ] &&
		! [[ "$NIXCAGE_ENTER_MEMORY" =~ ^[0-9]+[KMGT]?$ ]]; then
		echo "nixcage: not a memory size: $NIXCAGE_ENTER_MEMORY" >&2
		return 1
	fi
	if [ -n "$NIXCAGE_ENTER_CPUS" ] &&
		! [[ "$NIXCAGE_ENTER_CPUS" =~ ^[1-9][0-9]*$ ]]; then
		echo "nixcage: not a cpu count: $NIXCAGE_ENTER_CPUS" >&2
		return 1
	fi

	## The home is a destination inside the cage's own filesystem, so it is
	## held to the same spelling every other path is.
	if [ -n "$NIXCAGE_ENTER_HOME" ] &&
		! nixcage_bind_path_ok "$NIXCAGE_ENTER_HOME"; then
		echo "nixcage: not a usable home path: $NIXCAGE_ENTER_HOME" >&2
		return 1
	fi

	return 0
}

## A placement on a private network: <bridge>:<address>/<prefix>. The bridge
## name becomes an interface name on the host, so it is held to the kernel's
## fifteen characters and the alphabet an interface may carry; the address is
## one IPv4 address with its prefix, because it is set on the cage's veth and
## an address with no prefix is a route nobody chose. Both are the caller's;
## which veth and which capability set the cage gets are nixcage's.
##
## Or the network of a cage already running: ns:<path>, an absolute path to
## a network namespace such as /proc/<pid>/ns/net. The session joins it and
## sets nothing, because the cage that owns the namespace already did; a
## second veth for the same name and address would collide with the first.
nixcage_enter_network_arg() {
	local placement="$1"
	if [ "${placement#ns:}" != "$placement" ]; then
		local path="${placement#ns:}"
		if ! nixcage_bind_path_ok "$path"; then
			echo "nixcage: not a network namespace path: $placement" >&2
			return 1
		fi
		NIXCAGE_ENTER_NETWORK_NS="$path"
		return 0
	fi
	local bridge="${placement%%:*}" addr="${placement#*:}"
	if [ "$bridge" = "$placement" ] ||
		! [[ "$bridge" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,14}$ ]] ||
		! [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
		echo "nixcage: not a bridge placement: $placement" >&2
		return 1
	fi
	NIXCAGE_ENTER_NETWORK_BRIDGE="$bridge"
	NIXCAGE_ENTER_NETWORK_ADDR="$addr"
}

## The bounds as nspawn takes them, one argument per line: properties of
## the scope it allocates for the cage. A cpu count is a quota of that many
## whole cpus.
nixcage_enter_property_args() {
	[ -z "$NIXCAGE_ENTER_MEMORY" ] || printf -- '--property=MemoryMax=%s\n' "$NIXCAGE_ENTER_MEMORY"
	[ -z "$NIXCAGE_ENTER_CPUS" ] || printf -- '--property=CPUQuota=%s%%\n' "$((NIXCAGE_ENTER_CPUS * 100))"
}
