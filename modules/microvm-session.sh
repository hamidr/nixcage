# shellcheck shell=bash
## The host side of a microvm session (ADR-019): what is refused before
## anything boots, the watch over a boot, and the status enter exits with.
##
## The guest and the host share nothing but the home: the guest marks
## itself ready there before it runs argv, and leaves argv's status there
## before it powers off. Both are files the host reads after the fact, so
## the protocol is three files and a timer, and the lifecycle they make is
## the one models/microvm-session.qnt checks.
##
## Sourced by store path into nixcage-container.

## The marker the guest writes into its home once the session unit runs,
## and the file it leaves argv's status in. Spelt here and in
## guest-session.sh alike; read by the enter that sourced this.
# shellcheck disable=SC2034
NIXCAGE_MICROVM_READY=.nixcage-ready
# shellcheck disable=SC2034
NIXCAGE_MICROVM_EXIT=.nixcage-exit

## The seconds a guest has to become ready (decision 7).
# shellcheck disable=SC2034
NIXCAGE_MICROVM_BOOT_TIMEOUT=30

## nixcage_microvm_refusal <os> <guest> <kvm> <vmspawn version>
## The reason a microvm session cannot start here, on stderr, or nothing.
## Each is checked before vmspawn runs, because what vmspawn says when one
## of them is missing names qemu, a socket or a firmware, not the cause.
## 261 is the first vmspawn that boots a kernel directly without UEFI
## firmware (--firmware=none); 258 wants an OVMF it will not find here.
nixcage_microvm_refusal() {
	local os="$1" guest="$2" kvm="$3" version="$4"
	if [ "$os" = macos ]; then
		echo "nixcage: --substrate microvm is not available on macOS" >&2
		return 1
	fi
	if [ -z "$guest" ]; then
		echo "nixcage: this host builds no microvm guest: set nixcage.microvm.enable" >&2
		return 1
	fi
	if [ ! -e "$kvm" ]; then
		echo "nixcage: no /dev/kvm on this host" >&2
		return 1
	fi
	if [ -z "$version" ]; then
		echo "nixcage: systemd-vmspawn not found" >&2
		return 1
	fi
	if [ "$version" -lt 261 ]; then
		echo "nixcage: systemd-vmspawn $version is older than 261" >&2
		return 1
	fi
}

## nixcage_microvm_watch <ready marker> <name> <timeout> <stopped marker>
## Waits for the guest to mark itself ready; a guest that has not within
## the timeout is stopped through its scope and the stop is marked, so
## the outcome can tell a boot that failed from one that ended. Run in
## the background beside vmspawn, which holds the foreground and the tty.
nixcage_microvm_watch() {
	local ready="$1" name="$2" timeout="$3" stopped="$4"
	local waited=0
	while [ "$waited" -lt "$timeout" ]; do
		[ ! -e "$ready" ] || return 0
		sleep 1
		waited=$((waited + 1))
	done
	[ ! -e "$ready" ] || return 0
	: >"$stopped"
	machinectl terminate "$name" 2>/dev/null || true
}

## nixcage_microvm_outcome <ready marker> <exit file> <stopped marker>
## The status enter exits with, first on stdout, with the reason on stderr
## when it is not argv's own. A status the guest left is argv's whatever
## else happened, so it is read first: a guest the watch stopped after the
## status was written finished before it was heard from, which is not a
## failure. Then a stopped boot is 124, and anything else is a session
## that ended without saying how, which is 255 and never a success.
nixcage_microvm_outcome() {
	local ready="$1" exit_file="$2" stopped="$3"
	local status=""
	[ ! -f "$exit_file" ] || status="$(<"$exit_file")"
	if [[ "$status" =~ ^[0-9]+$ ]]; then
		echo "$status"
		return 0
	fi
	if [ -e "$stopped" ]; then
		echo 124
		echo "nixcage: session did not become ready within the boot timeout; stopped" >&2
		return 0
	fi
	echo 255
	echo "nixcage: session ended without status" >&2
}

## nixcage_microvm_ssh_target <name>
## The key vmspawn made for the VM and the address machined recorded for
## it, one per line: exec's whole transport (decision 6). machinectl shell
## does not reach a VM; ssh through systemd-ssh-proxy, which NixOS puts in
## ssh_config, does.
nixcage_microvm_ssh_target() {
	local name="$1" key address
	key="$(machinectl show "$name" -p SSHPrivateKeyPath --value 2>/dev/null)" &&
		address="$(machinectl show "$name" -p SSHAddress --value 2>/dev/null)" &&
		[ -n "$key" ] && [ -n "$address" ] || {
		echo "nixcage: $name has no ssh address: not a running microvm cage" >&2
		return 1
	}
	printf '%s\n' "$key" "$address"
}

## nixcage_exec_microvm_words <key> <address> <uid> <gid> <tty> [--setenv=K=V...] -- [cmd...]
## The words, one per line: ssh over vsock as the guest's root, then one
## remote line the guest's shell re-splits, so every word of it is quoted
## for bash. It becomes the session's uid in the workspace with the
## environment given and nothing else, as exec on nspawn becomes the
## subject with the leader's. The guest's host key is made at each boot,
## so none is kept or checked: the transport is vsock, which nothing but
## this host and that guest are on. env and setpriv are named by store
## path, which is the same file inside.
nixcage_exec_microvm_words() {
	local key="$1" address="$2" uid="$3" gid="$4" tty="$5"
	shift 5
	local -a env=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		env+=("${1#--setenv=}")
		shift
	done
	while [ "${1:-}" = "--" ]; do shift; done
	printf '%s\n' ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	[ -z "$tty" ] || printf '%s\n' -t
	printf '%s\n' -i "$key" "root@$address" --
	local remote="cd /workspace && exec"
	local word
	for word in "$NIXCAGE_EXEC_SETPRIV" "--reuid=$uid" "--regid=$gid" --clear-groups -- \
		"$NIXCAGE_EXEC_ENV" -i ${env[@]+"${env[@]}"} "${@:-bash}"; do
		remote+=" $(printf '%q' "$word")"
	done
	printf '%s\n' "$remote"
}

## nixcage_agent_forward_words <key> <address> <host socket>
## The ssh that carries the host's agent into the guest: a remote unix
## socket forward, so what appears in the guest is a socket sshd made,
## and no key material and no login shell go with it. -A would give the
## agent to root's login only, under a path only root can reach.
nixcage_agent_forward_words() {
	local key="$1" address="$2" sock="$3"
	printf '%s\n' ssh -q -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ExitOnForwardFailure=yes \
		-R "/run/ssh-agent.sock:$sock" -i "$key" "root@$address"
}

## nixcage_agent_forward <name> <host socket> <timeout>
## Forwards the agent for as long as the guest runs, from the moment its
## sshd answers: tried once a second until it holds or the timeout ends,
## since the VM registers before it boots. Run in the background beside
## vmspawn and killed when it returns.
nixcage_agent_forward() {
	local name="$1" sock="$2" timeout="$3" waited=0 key address
	while [ "$waited" -lt "$timeout" ]; do
		if { read -r key && read -r address; } < <(nixcage_microvm_ssh_target "$name" 2>/dev/null); then
			local -a words=()
			local word
			while IFS= read -r word; do
				words+=("$word")
			done < <(nixcage_agent_forward_words "$key" "$address" "$sock")
			if "${words[@]}"; then
				return 0
			fi
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

## nixcage_microvm_env_write <file> [--setenv=K=V...]
## What enter was asked by --setenv, kept for exec beside the record and
## readable by root alone: a value may be a token, and the record is
## readable by all. One word per NUL, so a value carrying a newline comes
## back as it was given. Written empty when nothing was asked, so exec
## reads the session's answer rather than the file's absence.
nixcage_microvm_env_write() {
	local file="$1"
	shift
	(umask 077 && : >"$file") || return 1
	[ $# -eq 0 ] || printf '%s\0' "$@" >"$file"
}

## The words back, NUL-terminated, or nothing.
nixcage_microvm_env_read() {
	[ -f "$1" ] || return 0
	cat "$1"
}
