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
	SESSION_AGENT="$(jq -r 'if .agent then 1 else "" end' "$cred")"
	SESSION_DNS="$(jq -r '.dns // ""' "$cred")"
	mapfile -d '' -t SESSION_ENV < <(jq -j '.env | to_entries[] | "\(.key)=\(.value)\u0000"' "$cred")
	mapfile -d '' -t SESSION_FILES < <(jq -j '(.files // [])[] | "\(.n)\t\(.dst)\t\(if .ro then "ro" else "rw" end)\u0000"' "$cred")
	mapfile -d '' -t SESSION_ARGV < <(jq -j '.argv[] | . + "\u0000"' "$cred")
}

## The one interface a placed guest has is the tap vmspawn made; it is
## given the placement's address here, as the first process of a placed
## nspawn session gives host0 its own.
## The interface is there once udev has named it, which is not
## necessarily before this unit runs; waited for, briefly.
nixcage_session_network() {
	[ -n "$SESSION_ADDRESS" ] || return 0
	local waited=0
	while [ ! -e /sys/class/net/eth0 ] && [ "$waited" -lt 10 ]; do
		sleep 1
		waited=$((waited + 1))
	done
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
	## Started as a job and waited for: bash reports a foreground child
	## the kernel killed on the console, which is argv's output, and says
	## nothing of a job. The status is the same either way.
	local setpriv
	setpriv="$(command -v setpriv)"
	if [ -n "$SESSION_TTY" ]; then
		env -i "${SESSION_ENV[@]}" "$setpriv" --reuid="$SESSION_UID" --regid="$SESSION_GID" \
			--clear-groups -- "${SESSION_ARGV[@]}" &
	else
		stty -onlcr
		env -i "${SESSION_ENV[@]}" "$setpriv" --reuid="$SESSION_UID" --regid="$SESSION_GID" \
			--clear-groups -- "${SESSION_ARGV[@]}" </dev/null &
	fi
	{ wait $!; } 2>/dev/null
}

## nixcage_session_resolv_conf <file>
## What a placed guest resolves with (ADR-016), as the nspawn rootfs is
## given it: none is an empty file, so glibc falls back to loopback and
## fails at once; an address is one nameserver line; told nothing, the
## guest's own file stands, which names nothing on a private network.
nixcage_session_resolv_conf() {
	local file="$1"
	case "$SESSION_DNS" in
	"") ;;
	none) : >"$file" ;;
	*) printf 'nameserver %s\n' "$SESSION_DNS" >"$file" ;;
	esac
}

## nixcage_session_files <share root> [runner]
## The files the host staged (ADR-020) arrive one per share under the
## root, each as "file" in its numbered directory, and each is put onto
## its target before argv runs: the target's directory made, the target
## touched so a bind has a mountpoint, the bind, and a read-only remount
## when the host asked for --bind-ro. A runner word, echo in the suite,
## goes before each command so what would run is read without a mount.
nixcage_session_files() {
	local root="$1" run="${2:-}" entry n dst mode
	for entry in ${SESSION_FILES[@]+"${SESSION_FILES[@]}"}; do
		IFS=$'\t' read -r n dst mode <<<"$entry"
		$run mkdir -p "${dst%/*}"
		$run touch "$dst"
		$run mount --bind "$root/$n/file" "$dst"
		[ "$mode" != ro ] || $run mount -o remount,bind,ro "$dst"
	done
}

## nixcage_session_account <passwd> <group>
## A name for the session's uid in the guest: tools ask getpwuid, and git
## refuses a committer that does not exist. The name is the login name
## the session was entered with, else nixcage; a uid the guest already
## names keeps its name. The guest's /etc is a tmpfs, so this is written,
## not rendered.
nixcage_session_account() {
	local passwd="$1" group="$2" name=nixcage word
	for word in ${SESSION_ENV[@]+"${SESSION_ENV[@]}"}; do
		case "$word" in
		USER=*) name="${word#USER=}" ;;
		esac
	done
	if ! grep -q "^[^:]*:[^:]*:$SESSION_UID:" "$passwd"; then
		printf '%s:x:%s:%s::%s:/bin/sh\n' "$name" "$SESSION_UID" "$SESSION_GID" "$SESSION_HOME" >>"$passwd"
	fi
	if ! grep -q "^[^:]*:[^:]*:$SESSION_GID:" "$group"; then
		printf '%s:x:%s:\n' "$name" "$SESSION_GID" >>"$group"
	fi
}

## nixcage_session_disk <device> <mountpoint>
## The image --disk gave the cage, handed in as the first virtio drive:
## made a filesystem the first time, mounted at /var/lib for the session's
## uid, for what virtiofs is too slow for and for what wants a block
## device of its own. The image is the cage's and outlives the session;
## the guest's /var around it does not.
nixcage_session_disk() {
	local device="$1" mountpoint="$2"
	[ -b "$device" ] || return 0
	if [ -z "$(blkid -o value -s TYPE "$device")" ]; then
		mkfs.ext4 -q "$device"
	fi
	mkdir -p "$mountpoint"
	mount "$device" "$mountpoint"
	chown "$SESSION_UID:$SESSION_GID" "$mountpoint"
}

## nixcage_session_agent_wait <socket> <timeout>
## The host forwards its agent as a socket over vsock ssh (ADR-008: a
## socket reaches the guest, a key never does), which it can only do once
## the guest's sshd answers, so the socket lands after this unit starts.
## Waited for, then given up on aloud: a session without an agent fails to
## sign, which is the nspawn outcome as well.
nixcage_session_agent_wait() {
	local sock="$1" timeout="$2" waited=0
	[ -n "$SESSION_AGENT" ] || return 0
	while [ ! -S "$sock" ] && [ "$waited" -lt "$timeout" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ -S "$sock" ] || echo "nixcage: no agent socket after ${timeout}s; commits cannot be signed" >&2
	return 0
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
	nixcage_session_resolv_conf /etc/resolv.conf
	nixcage_session_account /etc/passwd /etc/group
	nixcage_session_disk /dev/vda /var/lib
	nixcage_session_files /run/nixcage/bind
	nixcage_session_ready
	nixcage_session_agent_wait /run/ssh-agent.sock 15
	local status=0
	nixcage_session_run || status=$?
	nixcage_session_exit "$status" || true
}
