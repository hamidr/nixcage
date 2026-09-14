# shellcheck shell=bash
## A command inside a running cage (ADR-012 point 6).
##
## A cage is its leader's namespaces. Entering all of them, the user one
## included, puts a command in the same mounts, the same processes and the
## same uid map the session has; joining a user namespace grants full
## capabilities in it, so the command may then become a subject with
## setpriv exactly as a session does. Cage root, with no subject, is the
## principal's own host uid under --private-users.
##
## The command gets the leader's HOME and PATH and nothing of the caller's
## environment: what a session sees is what an exec sees.
##
## Sourced by store path into nixcage-container beside scope.sh, whose
## leader it takes; the suite drives it on a fixture proc tree.

## HOME and PATH as the leader has them, one assignment per line.
nixcage_exec_env() {
	local leader="$1"
	tr '\0' '\n' <"$NIXCAGE_PROC/$leader/environ" 2>/dev/null | grep -E '^(HOME|PATH)='
}

## The words, one per line: nsenter into the leader, then setpriv to the
## subject when an offset is given, then env -i with the leader's HOME and
## PATH, then the command or the cage's shell.
##
## nixcage_exec_words <leader> <subject-offset-or-empty> -- [cmd...]
nixcage_exec_words() {
	local leader="$1" offset="$2"
	shift 2
	[ "${1:-}" = "--" ] && shift
	printf '%s\n' nsenter "--target=$leader" --mount --uts --ipc --net --pid --user --wd=/workspace --
	if [ -n "$offset" ]; then
		printf '%s\n' setpriv "--reuid=$offset" "--regid=$offset" --clear-groups --
	fi
	printf '%s\n' env -i
	nixcage_exec_env "$leader"
	if [ $# -gt 0 ]; then
		printf '%s\n' "$@"
	else
		printf '%s\n' bash
	fi
}
