# shellcheck shell=bash
## nixcage makes a cage's veth and names it (ADR-013), and pins the port to
## its placement (ADR-015).
##
## nspawn's own veth is named after the machine, which bounds a cage's name
## by an interface name's fifteen characters. A pair nixcage makes carries
## a host end named from a hash of the cage's name, fits any name, and is
## handed to nspawn under --network-interface with the cage end renamed to
## the host0 every session expects.
##
## The port speaks only as its address and never to a peer port: a table
## nixcage makes at runtime holds one element per port and two chains that
## drop what does not match, and the kernel's port isolation drops
## port-to-port before any chain runs. The table is declared to no NixOS
## module, so the host's firewall backend is not decided here and a reload
## of the host's ruleset does not know the table exists.
##
## Sourced by store path into nixcage-container; the suite drives it with
## ip, nft and bridge stubbed.

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

## The table, its set and its two chains, made if missing and the chains
## refilled either way, which leaves the set and the pins in it alone. Add
## is idempotent where create is not, so a second make finds everything
## there and changes nothing but the rules. The port prefix is matched here
## rather than each port named, so a rule reads the same for every cage.
nixcage_veth_table_ensure() {
	nft add table bridge nixcage &&
		nft add set bridge nixcage placements '{ type ifname . ipv4_addr ; }' &&
		nft add chain bridge nixcage prerouting '{ type filter hook prerouting priority -300 ; policy accept ; }' &&
		nft add chain bridge nixcage forward '{ type filter hook forward priority 0 ; policy accept ; }' &&
		nft flush chain bridge nixcage prerouting &&
		nft add rule bridge nixcage prerouting iifname '"nc-*"' ether type ip6 drop &&
		nft add rule bridge nixcage prerouting iifname '"nc-*"' ether type arp iifname . arp saddr ip != @placements drop &&
		nft add rule bridge nixcage prerouting iifname '"nc-*"' ether type ip iifname . ip saddr != @placements drop &&
		nft flush chain bridge nixcage forward &&
		nft add rule bridge nixcage forward iifname '"nc-*"' oifname '"nc-*"' drop
}

## Whatever the set holds under this host end goes: a pin from a session
## that was killed, or the pin of the session ending now. The set's key is
## the pair, so the elements are read back to be named.
nixcage_veth_unpin() {
	local host="$1" element
	while IFS= read -r element; do
		nft delete element bridge nixcage placements "{ $element }" || return 1
	done < <(nft list set bridge nixcage placements 2>/dev/null |
		grep -oE "\"$host\" \. [0-9]+(\.[0-9]+){3}")
}

## The pair, its host end on the bridge, pinned to the address, isolated,
## and up in that order, so no frame crosses before the pin is on. The cage
## end gets its address inside the cage, as ADR-011 has it. A host end
## already there is a session that was killed rather than ended and took no
## trap with it; the name is the cage's, so the stale pair goes before the
## new one comes. The address is the placement's, with or without its
## prefix; the pin is the address alone.
nixcage_veth_make() {
	local name="$1" bridge="$2" addr="${3:-}" host cage
	[ -n "$addr" ] || return 1
	addr="${addr%%/*}"
	host="$(nixcage_veth_host_name "$name")" || return 1
	cage="$(nixcage_veth_cage_name "$name")" || return 1
	nixcage_veth_table_ensure || return 1
	if ip link show "$host" >/dev/null 2>&1; then
		ip link del "$host" || return 1
	fi
	ip link add "$host" type veth peer name "$cage" &&
		ip link set "$host" master "$bridge" &&
		nixcage_veth_unpin "$host" &&
		nft add element bridge nixcage placements "{ \"$host\" . $addr }" &&
		bridge link set dev "$host" isolated on &&
		ip link set "$host" up
}

## Deleting one end of a veth deletes the pair, wherever the other end is.
## The pin goes first, so the set never names a port that is gone.
nixcage_veth_delete() {
	local host
	host="$(nixcage_veth_host_name "$1")" || return 1
	nixcage_veth_unpin "$host" || return 1
	ip link del "$host"
}

## What nspawn is handed: the cage end, renamed host0 inside.
nixcage_veth_nspawn_arg() {
	local cage
	cage="$(nixcage_veth_cage_name "$1")" || return 1
	printf -- '--network-interface=%s:host0\n' "$cage"
}

## A microVM's port (ADR-019): a tap under the same host name, on the
## bridge, pinned and isolated the same, and up in the same order. vmspawn
## would name its own tap after the machine and shorten it by a hash of
## its own, and a host running networkd would give a vt-* tap a masquerade
## it ships a network file for; a tap nixcage makes has nixcage's name and
## nixcage's rules before the guest boots, and qemu is handed it by name.
nixcage_tap_make() {
	local name="$1" bridge="$2" addr="${3:-}" host
	[ -n "$addr" ] || return 1
	addr="${addr%%/*}"
	host="$(nixcage_veth_host_name "$name")" || return 1
	nixcage_veth_table_ensure || return 1
	if ip link show "$host" >/dev/null 2>&1; then
		ip link del "$host" || return 1
	fi
	ip tuntap add dev "$host" mode tap &&
		ip link set "$host" master "$bridge" &&
		nixcage_veth_unpin "$host" &&
		nft add element bridge nixcage placements "{ \"$host\" . $addr }" &&
		bridge link set dev "$host" isolated on &&
		ip link set "$host" up
}

nixcage_tap_delete() {
	nixcage_veth_delete "$1"
}

## What qemu is handed through vmspawn's extra words: the tap by name, no
## script to run on it, one virtio interface the guest sees as eth0.
nixcage_tap_qemu_words() {
	local host
	host="$(nixcage_veth_host_name "$1")" || return 1
	printf '%s\n' -netdev "tap,id=nixcage0,ifname=$host,script=no,downscript=no" \
		-device virtio-net-pci,netdev=nixcage0
}
