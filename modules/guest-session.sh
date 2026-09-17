# shellcheck shell=bash
## The guest side of a microvm session (ADR-019): what nixcage-session.service
## runs once the guest is up. vmspawn boots an init and takes no command, so
## argv, its environment, who runs it and where came in as one credential;
## this reads it, runs argv on the console as that uid, leaves the exit
## status in the home share where the host reads it, and powers off.
##
## Sourced by store path into the session unit's script in guest.nix; the
## reader is a function of one file so the suite drives it on fixtures.

## nixcage_session_read <credential file>
## The credential's fields into globals, argv and env as arrays. jq writes
## each element NUL-terminated, so a value carrying a newline or a space
## arrives as it was given.
# shellcheck disable=SC2034
nixcage_session_read() {
	local cred="$1"
	SESSION_UID="$(jq -r '.uid' "$cred")"
	SESSION_GID="$(jq -r '.gid' "$cred")"
	SESSION_HOME="$(jq -r '.home' "$cred")"
	SESSION_CWD="$(jq -r '.cwd' "$cred")"
	SESSION_TTY="$(jq -r 'if .tty then 1 else "" end' "$cred")"
	SESSION_ADDRESS="$(jq -r '.address // ""' "$cred")"
	mapfile -d '' -t SESSION_ENV < <(jq -j '.env | to_entries[] | "\(.key)=\(.value)\u0000"' "$cred")
	mapfile -d '' -t SESSION_ARGV < <(jq -j '.argv[] | . + "\u0000"' "$cred")
}

## The one interface a placed guest has is the tap vmspawn made; it is
## given the placement's address here, as the first process of a placed
## nspawn session gives host0 its own.
nixcage_session_network() {
	[ -n "$SESSION_ADDRESS" ] || return 0
	ip addr add "$SESSION_ADDRESS" dev eth0
	ip link set eth0 up
}

## argv as the session's uid, with only the environment it was given, on
## the console: vmspawn shows the console to the host, interactively when
## enter had a tty and read-only when not, so a session without one gets
## no stdin rather than a console nobody types on.
## The console is a tty either way; without one asked for, the line
## discipline is told not to turn newlines into carriage returns, so what
## the host captures is what argv wrote.
nixcage_session_run() {
	cd "$SESSION_CWD" || return 1
	## env -i resolves what follows through the environment it just
	## emptied, so the switch is named by its path.
	local setpriv
	setpriv="$(command -v setpriv)"
	if [ -n "$SESSION_TTY" ]; then
		env -i "${SESSION_ENV[@]}" "$setpriv" --reuid="$SESSION_UID" --regid="$SESSION_GID" \
			--clear-groups -- "${SESSION_ARGV[@]}"
	else
		stty -onlcr
		env -i "${SESSION_ENV[@]}" "$setpriv" --reuid="$SESSION_UID" --regid="$SESSION_GID" \
			--clear-groups -- "${SESSION_ARGV[@]}" </dev/null
	fi
}

## Ready: the session unit is up and argv is about to run. The host waits
## for this file rather than for vmspawn's own READY=1, which reaches
## vmspawn and nobody behind it; it crosses on the share the status does,
## written the same way.
nixcage_session_ready() {
	local file="$SESSION_HOME/.nixcage-ready"
	setpriv --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups -- touch "$file" &&
		setpriv --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups -- sync "$file"
}

## The status, written as the session's uid so the home stays its own, and
## fsynced before the poweroff: virtiofs holds a write in the guest's page
## cache until then, and a status that never reached the host is a session
## the host reports as ended without one.
nixcage_session_exit() {
	local status="$1" file="$SESSION_HOME/.nixcage-exit"
	printf '%s\n' "$status" |
		setpriv --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups -- tee "$file" >/dev/null &&
		setpriv --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups -- sync "$file"
}

## The guest ends whatever happened: a credential that could not be read
## or a status that could not be written is a session the host sees end
## without a status, not a VM that waits out the host's timeout.
nixcage_session_main() {
	trap 'systemctl poweroff' EXIT
	nixcage_session_read "$CREDENTIALS_DIRECTORY/nixcage.session"
	nixcage_session_network
	nixcage_session_ready
	local status=0
	nixcage_session_run || status=$?
	nixcage_session_exit "$status" || true
}
