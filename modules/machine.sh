# shellcheck shell=bash
## A machine (ADR-026): a long-lived microVM that is itself a nixcage host,
## started and stopped by this host alone, and reached by the verbs over a
## cage with --machine.
##
## The host module renders one file per machine under the machines
## directory; this reads it, builds the vmspawn line the machine's unit
## runs, says what state the host sees it in, and spells the ssh words a
## verb is forwarded with. Nothing here trusts the guest: what it answers
## is passed to the caller, and what the host must do waits on nothing it
## says.
##
## Sourced by store path into nixcage-container, after scope.sh (the name
## check) and microvm-session.sh (the ssh configuration words); the suite
## sources it with the machines directory pointed at a fixture.

NIXCAGE_MACHINES_DIR="${NIXCAGE_MACHINES_DIR:-/etc/nixcage/machines}"
## How long up waits for the guest to answer, and down for it to stop its
## cages, before the host decides without it. A machine boots a whole
## NixOS, which a session's guest does not.
NIXCAGE_MACHINE_TIMEOUT="${NIXCAGE_MACHINE_TIMEOUT:-120}"

nixcage_machine_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && [ "${#1}" -le 64 ]
}

nixcage_machine_declared() {
	nixcage_machine_name_ok "$1" && [ -f "$NIXCAGE_MACHINES_DIR/$1" ]
}

## nixcage_machine_read <name>
## Sets MACHINE_* from the machine's file: KEY=VALUE lines, the value
## everything after the first equals sign, unquoted. A key this reader does
## not know is ignored, so a module newer than this script can add one.
# shellcheck disable=SC2034
nixcage_machine_read() {
	local name="$1" key value
	if ! nixcage_machine_name_ok "$name"; then
		echo "nixcage: invalid machine name: $name" >&2
		return 1
	fi
	if ! nixcage_machine_declared "$name"; then
		echo "nixcage: this host declares no machine $name" >&2
		return 1
	fi
	MACHINE_TOPLEVEL="" MACHINE_MEMORY="" MACHINE_CPUS="" MACHINE_DISK_SIZE=""
	MACHINE_UID_BASE="" MACHINE_UID_SIZE="" MACHINE_STORE_BASE=""
	MACHINE_SHARES=() MACHINE_BRIDGE="" MACHINE_ADDRESSES=()
	while IFS='=' read -r key value; do
		case "$key" in
		TOPLEVEL) MACHINE_TOPLEVEL="$value" ;;
		MEMORY) MACHINE_MEMORY="$value" ;;
		CPUS) MACHINE_CPUS="$value" ;;
		DISK_SIZE) MACHINE_DISK_SIZE="$value" ;;
		UID_BASE) MACHINE_UID_BASE="$value" ;;
		UID_SIZE) MACHINE_UID_SIZE="$value" ;;
		STORE_BASE) MACHINE_STORE_BASE="$value" ;;
		SHARES) read -ra MACHINE_SHARES <<<"$value" ;;
		BRIDGE) MACHINE_BRIDGE="$value" ;;
		ADDRESSES) read -ra MACHINE_ADDRESSES <<<"$value" ;;
		esac
	done <"$NIXCAGE_MACHINES_DIR/$name"
	local field
	for field in TOPLEVEL DISK_SIZE UID_BASE UID_SIZE STORE_BASE; do
		value="MACHINE_$field"
		if [ -z "${!value}" ]; then
			echo "nixcage: machine $name's declaration names no $field" >&2
			return 1
		fi
	done
	if [ -n "$MACHINE_BRIDGE" ] && [ "${#MACHINE_ADDRESSES[@]}" -eq 0 ]; then
		echo "nixcage: machine $name is placed on $MACHINE_BRIDGE with no address to speak as" >&2
		return 1
	fi
}

## nixcage_machine_unit <name>
nixcage_machine_unit() {
	printf 'nixcage-machine-%s.service\n' "$1"
}

## nixcage_machine_vmspawn_args <name> <skeleton> <toplevel> <uid base> <uid size> <memory> <cpus> <disk> <extra>
## The line the machine's unit runs, one word per line, as ADR-019's
## session line is built but for a guest that stays: its own init,
## readiness from that init rather than from a session unit, a console
## nobody attaches to, and a journal kept in the guest. The skeleton is the
## root share, shifted onto the machine's slice so what guest root writes
## there is an unprivileged uid on this host. The disk is the file only
## qemu opens (decision 3).
nixcage_machine_vmspawn_args() {
	local name="$1" skeleton="$2" toplevel="$3" base="$4" size="$5"
	local memory="$6" cpus="$7" disk="$8" extra="$9"
	printf '%s\n' env \
		"SYSTEMD_VMSPAWN_QEMU_EXTRA=-append 'root=root rootfstype=virtiofs rw init=$toplevel/init console=hvc0 net.ifnames=0 systemd.show_status=0 TERM=dumb'${extra:+ $extra}" \
		systemd-vmspawn \
		--quiet --register=yes --notify-ready=yes \
		"--machine=$name" \
		"--directory=$skeleton" \
		"--linux=$toplevel/kernel" \
		"--initrd=$toplevel/initrd" \
		--firmware=none \
		"--private-users=$base:$size" \
		--console=read-only
	[ -z "$memory" ] || printf -- '--ram=%s\n' "$memory"
	[ -z "$cpus" ] || printf -- '--cpus=%s\n' "$cpus"
	printf -- '--extra-drive=%s\n' "$disk"
	printf '%s\n' --bind-ro=/nix/store
}

## nixcage_machine_state <unit ActiveState> <probe status>
## What the host reports: the unit's state, and for an active unit whether
## the guest's nixcage-container answered. Only the host's own view: a
## guest cannot make a machine read ready without its unit being active.
nixcage_machine_state() {
	case "$1" in
	active) [ "$2" = 0 ] && echo ready || echo booting ;;
	activating | reloading) echo booting ;;
	deactivating) echo stopping ;;
	failed) echo failed ;;
	*) echo off ;;
	esac
}

## nixcage_machine_forward_words <key> <address> <tty> <agent> -- <remote argv...>
## ssh over vsock as the guest's root, then one remote line the guest's
## shell re-splits, every word quoted for bash. <agent>, when set, is
## "GUEST:HOST": a socket forward from the guest's path to the caller's
## agent, made by this host's ssh. The guest's host key is made at its boot
## and not kept: the transport is vsock, which only this host and that
## guest are on.
nixcage_machine_forward_words() {
	local key="$1" address="$2" tty="$3" agent="$4"
	shift 4
	[ "${1:-}" != -- ] || shift
	printf '%s\n' ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	nixcage_microvm_ssh_config_words
	[ -z "$tty" ] || printf '%s\n' -t
	[ -z "$agent" ] || printf '%s\n' -o StreamLocalBindUnlink=yes -R "$agent"
	printf '%s\n' -i "$key" "root@$address" --
	local remote="" word
	for word in "$@"; do
		remote+="${remote:+ }$(printf '%q' "$word")"
	done
	printf '%s\n' "$remote"
}

## nixcage_machine_enter_words <closure> <guest agent path> <enter args...>
## The guest's enter line, one word per line: no daemon, since a machine
## has none (decision 2), and the closure this host computed, since the
## guest has the store without its database (decision 6). An agent path
## is replaced by the one the forward lands at. Only the options are read:
## the first word that is not one is the cage's name, and everything from
## there on is the caller's, however it is spelt.
nixcage_machine_enter_words() {
	local closure="$1" agent="$2"
	shift 2
	local -a out=(enter --no-nix-daemon --store-closure "$closure")
	while [ $# -gt 0 ]; do
		case "$1" in
		--no-nix-daemon) shift ;;
		--no-agent | --print-argv)
			out+=("$1")
			shift
			;;
		--auth-sock)
			out+=("$1" "${agent:-$2}")
			shift 2 || return 1
			;;
		--*)
			out+=("$1" "${2:-}")
			shift 2 || return 1
			;;
		*) break ;;
		esac
	done
	out+=("$@")
	printf '%s\n' "${out[@]}"
}

## nixcage_machine_share_words <path> <ro|rw> <socket> <slice base> <slice size>
## The virtiofsd a share is served by (decision 5), one word per line,
## started by the machine's unit rather than by vmspawn, whose --bind maps
## no ids. Read-only unless declared writable. A writable share maps guest
## uid and gid 0 onward onto the slice, so guest root is its base here, and
## refuses every id beyond the slice, so no file here can be made to belong
## to a host id the machine was not given.
nixcage_machine_share_words() {
	local path="$1" mode="$2" sock="$3" base="$4" size="$5"
	printf '%s\n' virtiofsd "--shared-dir=$path" "--socket-path=$sock" --sandbox=namespace
	if [ "$mode" != rw ]; then
		printf '%s\n' --readonly
		return 0
	fi
	local beyond=$((4294967295 - size)) kind
	for kind in uid gid; do
		printf -- '--translate-%s=map:0:%s:%s\n' "$kind" "$base" "$size"
		printf -- '--translate-%s=forbid-guest:%s:%s\n' "$kind" "$size" "$beyond"
	done
}

## nixcage_machine_share_qemu_words <index> <socket>
## What qemu is handed for one share, on one line for vmspawn's extra
## words: the socket as a chardev and a vhost-user-fs device tagged by the
## share's position, which is the tag the guest mounts.
nixcage_machine_share_qemu_words() {
	local i="$1" sock="$2"
	printf -- '-chardev socket,id=nixcage-share%s,path=%s -device vhost-user-fs-pci,chardev=nixcage-share%s,tag=nixcage-share%s\n' \
		"$i" "$sock" "$i" "$i"
}

## nixcage_machine_share_mount_ok <mount options>
## Whether the host mount a writable share lives on keeps what the guest
## writes from meaning anything here: no setuid, no device nodes.
nixcage_machine_share_mount_ok() {
	local opts=",$1,"
	[[ "$opts" == *,nosuid,* ]] && [[ "$opts" == *,nodev,* ]]
}
