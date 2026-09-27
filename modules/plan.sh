# shellcheck shell=bash
## A guest's proposed enter or exec line, validated before the host runs it
## (ADR-027).
##
## A machine's guest holds a factory's state (ADR-026 point 3) and so is
## where the words of an enter or exec line get composed; only the host can
## run them (ADR-026 point 6: the guest has the store without its
## database). A dependant's own program in the guest writes that line to
## stdout; the host reads it here before running it.
##
## The grammar is fixed and owned here, not by a dependant: only enter and
## exec are namable, and a guest may not choose its own --auth-sock or
## point at a different --machine than the one plan was invoked for. Which
## machine runs is plan's own argument, never the guest's word.
##
## Sourced by store path into nixcage-container beside enter-args.sh and
## exec-cage.sh; the suite drives it on words it composes.

## nixcage_plan_words <machine> <auth-sock-or-empty> -- <verb> [word...]
##
## Prints the composed nixcage-container argv, NUL-terminated, on success.
## On refusal prints nothing to stdout and returns 1 with the reason on
## stderr.
nixcage_plan_words() {
	local machine="$1" auth_sock="$2"
	shift 2
	## The verb's own separator, and the caller's when they wrote one too.
	while [ "${1:-}" = "--" ]; do shift; done
	local verb="${1:-}"
	case "$verb" in
	enter | exec) ;;
	*)
		echo "nixcage: a plan may only run enter or exec, not ${verb:-<empty>}" >&2
		return 1
		;;
	esac
	shift
	local word
	for word in "$@"; do
		case "$word" in
		--auth-sock | --machine)
			echo "nixcage: a plan may not name $word itself" >&2
			return 1
			;;
		esac
	done
	printf '%s\0' "$verb" --machine "$machine"
	if [ -n "$auth_sock" ]; then
		printf '%s\0' --auth-sock "$auth_sock"
	fi
	if [ $# -gt 0 ]; then
		printf '%s\0' "$@"
	fi
}

## nixcage_plan_machine_guest_refusal <machine-guest>
##
## plan never runs inside a machine (ADR-026's MACHINE_GUEST flag): a plan
## proposing itself to itself defeats the boundary it exists to hold.
nixcage_plan_machine_guest_refusal() {
	local machine_guest="$1"
	if [ -n "$machine_guest" ]; then
		echo "nixcage: plan is refused inside a machine; a plan proposing itself to itself defeats the boundary it exists to hold" >&2
		return 1
	fi
}
