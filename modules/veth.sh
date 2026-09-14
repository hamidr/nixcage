# shellcheck shell=bash
## nixcage makes a cage's veth and names it (ADR-013).
##
## nspawn's own veth is named after the machine, which bounds a cage's name
## by an interface name's fifteen characters. A pair nixcage makes carries
## a host end named from a hash of the cage's name, fits any name, and is
## handed to nspawn under --network-interface with the cage end renamed to
## the host0 every session expects.
##
## Sourced by store path into nixcage-container; the suite drives it with
## ip stubbed.

nixcage_veth_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9-]+$ ]]
}

## Twelve hex digits of the name's hash: stable, and fifteen characters
## with the prefix for any name.
nixcage_veth_digest() {
	printf '%s' "$1" | sha256sum | cut -c1-12
}

nixcage_veth_host_name() {
	nixcage_veth_name_ok "$1" || return 1
	printf 'nc-%s\n' "$(nixcage_veth_digest "$1")"
}

## The cage end, one letter apart, alive only until nspawn renames it.
nixcage_veth_cage_name() {
	nixcage_veth_name_ok "$1" || return 1
	printf 'cc-%s\n' "$(nixcage_veth_digest "$1")"
}

## The pair, its host end on the bridge and up. The cage end gets its
## address inside the cage, as ADR-011 has it. A host end already there is
## a session that was killed rather than ended and took no trap with it;
## the name is the cage's, so the stale pair goes before the new one comes.
nixcage_veth_make() {
	local name="$1" bridge="$2" host cage
	host="$(nixcage_veth_host_name "$name")" || return 1
	cage="$(nixcage_veth_cage_name "$name")" || return 1
	if ip link show "$host" >/dev/null 2>&1; then
		ip link del "$host" || return 1
	fi
	ip link add "$host" type veth peer name "$cage" &&
		ip link set "$host" master "$bridge" &&
		ip link set "$host" up
}

## Deleting one end of a veth deletes the pair, wherever the other end is.
nixcage_veth_delete() {
	local host
	host="$(nixcage_veth_host_name "$1")" || return 1
	ip link del "$host"
}

## What nspawn is handed: the cage end, renamed host0 inside.
nixcage_veth_nspawn_arg() {
	local cage
	cage="$(nixcage_veth_cage_name "$1")" || return 1
	printf -- '--network-interface=%s:host0\n' "$cage"
}
