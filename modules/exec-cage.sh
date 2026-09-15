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

## Where env and setpriv are, by store path: nsenter looks the command up
## after entering, with the caller's PATH, in a filesystem where that PATH
## names nothing, and the cage's profile has no setpriv at all. The store
## is the same inside, so a store path is the same file. The wrapper sets
## these from its own inputs; the suite from a fixture.
NIXCAGE_EXEC_ENV="${NIXCAGE_EXEC_ENV:-env}"
NIXCAGE_EXEC_SETPRIV="${NIXCAGE_EXEC_SETPRIV:-setpriv}"

## The words, one per line: nsenter into the leader, then setpriv to the
## subject when an offset is given, then env -i with the leader's HOME and
## PATH, then the command or the cage's shell. The working directory is
## --wdns, resolved inside the cage's mount namespace: util-linux 2.42's
## --wd opens the path on the host first, where /workspace is nothing.
##
## nixcage_exec_words <leader> <subject-offset-or-empty> -- [cmd...]
nixcage_exec_words() {
	local leader="$1" offset="$2"
	shift 2
	[ "${1:-}" = "--" ] && shift
	printf '%s\n' nsenter "--target=$leader" --mount --uts --ipc --net --pid --user --wdns=/workspace --
	if [ -n "$offset" ]; then
		printf '%s\n' "$NIXCAGE_EXEC_SETPRIV" "--reuid=$offset" "--regid=$offset" --clear-groups --
	fi
	printf '%s\n' "$NIXCAGE_EXEC_ENV" -i
	nixcage_exec_env "$leader"
	if [ $# -gt 0 ]; then
		printf '%s\n' "$@"
	else
		printf '%s\n' bash
	fi
}
