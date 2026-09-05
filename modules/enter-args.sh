# shellcheck shell=bash
## The options `enter` is parameterised with (ADR-009).
##
## This is nixcage's exported interface, so it is a shell file rather than a
## loop inside the Nix string that builds nixcage-container: the suite sources
## this and drives it directly, and an interface nothing can drive is one that
## breaks at a dependant's run time instead of at ours.
##
## Sourced by store path into nixcage-container, beside bind.sh, whose checks
## every asked-for bind and variable goes through.

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
	NIXCAGE_ENTER_HOME=""
	NIXCAGE_ENTER_SHELL=""
	NIXCAGE_ENTER_AUTH_SOCK=""
	NIXCAGE_ENTER_NO_AGENT=""
	NIXCAGE_ENTER_BINDS=()
	NIXCAGE_ENTER_ENV=()
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
		--home)
			NIXCAGE_ENTER_HOME="${2:-}"
			shift 2 || return 1
			;;
		--shell)
			NIXCAGE_ENTER_SHELL="${2:-}"
			shift 2 || return 1
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

	if [ -n "$NIXCAGE_ENTER_UID" ] &&
		! [[ "$NIXCAGE_ENTER_UID" =~ ^[0-9]+$ ]]; then
		echo "nixcage: not a uid: $NIXCAGE_ENTER_UID" >&2
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
