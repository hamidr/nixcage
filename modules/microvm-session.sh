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
