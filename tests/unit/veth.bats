#!/usr/bin/env bats
# nixcage makes a cage's veth and names it (ADR-013): the names, the ip
# words that make and delete the pair, and the argument nspawn gets. And it
# pins the placement on its port and isolates the port (ADR-015): the nft
# and bridge words around the ip words. Driven with all three stubbed so
# nothing touches an interface or a ruleset; every call lands in one file,
# tool first, so the order across tools is what is asserted.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/veth.sh
	source "$NIXCAGE_ROOT/modules/veth.sh"
	CALLS="$TEST_TEMP_DIR/calls"
	mkdir -p "$TEST_TEMP_DIR/bin"
	# No interface exists until made: "link show" answers as ip does for
	# a name it does not have. An empty set lists as nothing to nft.
	local tool
	for tool in ip nft bridge udevadm; do
		printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"%s"\ncase "$1 $2" in "link show") exit 1 ;; esac\n' "$tool" "$CALLS" >"$TEST_TEMP_DIR/bin/$tool"
		chmod +x "$TEST_TEMP_DIR/bin/$tool"
	done
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# The ip words alone, in order, for the scenarios that are about the pair.
ip_calls() {
	grep '^ip ' "$CALLS"
}

# An nft that lists one element under the host end, as a set does after a
# session that was killed, or while a session runs.
stub_nft_listing() {
	cat >"$TEST_TEMP_DIR/bin/nft" <<EOF
#!/usr/bin/env bash
printf "nft %s\\n" "\$*" >>"$CALLS"
case "\$*" in
"list set bridge nixcage placements")
	printf 'table bridge nixcage {\\n\\tset placements {\\n\\t\\ttype ifname . ipv4_addr\\n\\t\\telements = { "%s" . %s,\\n\\t\\t\\t     "nc-000000000000" . 10.77.0.2 }\\n\\t}\\n}\\n' "$1" "$2"
	;;
esac
EOF
}

teardown() {
	teardown_temp_dir
}

@test "the host end is nc- and twelve hex digits of the name's hash, fifteen characters for any name" {
	run nixcage_veth_host_name builder
	assert_success
	assert_output --regexp '^nc-[0-9a-f]{12}$'
	run nixcage_veth_host_name a-cage-name-well-past-twelve-characters
	assert_success
	assert_output --regexp '^nc-[0-9a-f]{12}$'
}

@test "the same name always gives the same host end, and two names give two" {
	[ "$(nixcage_veth_host_name builder)" = "$(nixcage_veth_host_name builder)" ]
	[ "$(nixcage_veth_host_name builder)" != "$(nixcage_veth_host_name reviewer)" ]
}

@test "the cage end differs from the host end by one letter and lives only until nspawn renames it" {
	local host cage
	host="$(nixcage_veth_host_name builder)"
	cage="$(nixcage_veth_cage_name builder)"
	[ "${host#nc-}" = "${cage#cc-}" ]
	[ "${#cage}" -le 15 ]
}

@test "making the pair adds it, puts the host end on the bridge, and brings it up" {
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	local host cage
	host="$(nixcage_veth_host_name builder)"
	cage="$(nixcage_veth_cage_name builder)"
	run ip_calls
	assert_line --index 0 "ip link show $host"
	assert_line --index 1 "ip link add $host type veth peer name $cage"
	assert_line --index 2 "ip link set $host master fabriek-acme"
	assert_line --index 3 "ip link set $host up"
}

@test "a make without an address is refused, because a port without a pin would pass anything" {
	run nixcage_veth_make builder fabriek-acme
	assert_failure
	[ ! -e "$CALLS" ]
}

@test "the first make creates the table, the set and the two chains, and refills the chains" {
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	run grep '^nft ' "$CALLS"
	assert_line --index 0 "nft add table bridge nixcage"
	assert_line --index 1 "nft add set bridge nixcage placements { type ifname . ipv4_addr ; }"
	assert_line --index 2 "nft add chain bridge nixcage prerouting { type filter hook prerouting priority -300 ; policy accept ; }"
	assert_line --index 3 "nft add chain bridge nixcage forward { type filter hook forward priority 0 ; policy accept ; }"
	assert_line --index 4 "nft flush chain bridge nixcage prerouting"
	assert_line --index 5 'nft add rule bridge nixcage prerouting iifname "nc-*" ether type ip6 drop'
	assert_line --index 6 'nft add rule bridge nixcage prerouting iifname "nc-*" ether type arp iifname . arp saddr ip != @placements drop'
	assert_line --index 7 'nft add rule bridge nixcage prerouting iifname "nc-*" ether type ip iifname . ip saddr != @placements drop'
	assert_line --index 8 "nft flush chain bridge nixcage forward"
	assert_line --index 9 'nft add rule bridge nixcage forward iifname "nc-*" oifname "nc-*" drop'
}

@test "the table is made before the pair, so no port exists without the rules on it" {
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	local first_ip first_nft
	first_ip="$(grep -n '^ip ' "$CALLS" | head -1 | cut -d: -f1)"
	first_nft="$(grep -n '^nft ' "$CALLS" | head -1 | cut -d: -f1)"
	[ "$first_nft" -lt "$first_ip" ]
}

@test "a make pins the placement once the host end is on the bridge, isolates the port, and only then brings it up" {
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	local host
	host="$(nixcage_veth_host_name builder)"
	run grep -vE '^nft (add (table|set|chain|rule)|flush)' "$CALLS"
	assert_line --index 0 "ip link show $host"
	assert_line --index 1 "ip link add $host type veth peer name $(nixcage_veth_cage_name builder)"
	assert_line --index 2 "ip link set $host master fabriek-acme"
	assert_line --index 3 "nft list set bridge nixcage placements"
	assert_line --index 4 "nft add element bridge nixcage placements { \"$host\" . 10.77.0.10 }"
	assert_line --index 5 "bridge link set dev $host isolated on"
	assert_line --index 6 "ip link set $host up"
}

# nspawn refuses a --network-interface udev has not finished with ("Network
# interface ... is not initialized yet"), and a pair just made often is not:
# 2 enters in 12 failed on a NixOS host (found 2026-09-24). The make waits
# for udev on the cage end, last, once everything else about it is done.
@test "a make waits for udev to finish with the cage end before handing it on" {
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	run tail -1 "$CALLS"
	assert_output "udevadm wait --initialized=yes --timeout=10 /sys/class/net/$(nixcage_veth_cage_name builder)"
}

@test "a make under a name with a stale element deletes that element before adding its own, and no other" {
	local host
	host="$(nixcage_veth_host_name builder)"
	stub_nft_listing "$host" 10.77.0.9
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	run grep '^nft .*element' "$CALLS"
	assert_line --index 0 "nft delete element bridge nixcage placements { \"$host\" . 10.77.0.9 }"
	assert_line --index 1 "nft add element bridge nixcage placements { \"$host\" . 10.77.0.10 }"
	refute_output --partial "nc-000000000000"
}

@test "a host end left behind by a session that was killed is deleted before the pair is made again" {
	# A wrapper ended by SIGTERM runs no EXIT trap; the next session for the
	# same name found "RTNETLINK answers: File exists" and never started.
	local host
	host="$(nixcage_veth_host_name builder)"
	cat >"$TEST_TEMP_DIR/bin/ip" <<EOF
#!/usr/bin/env bash
printf "ip %s\\n" "\$*" >>"$CALLS"
case "\$*" in
"link show $host") [ -e "$TEST_TEMP_DIR/stale" ] ;;
"link del $host") rm -f "$TEST_TEMP_DIR/stale" ;;
esac
EOF
	touch "$TEST_TEMP_DIR/stale"
	run nixcage_veth_make builder fabriek-acme 10.77.0.10/24
	assert_success
	run ip_calls
	assert_line --index 0 "ip link show $host"
	assert_line --index 1 "ip link del $host"
	assert_line --index 2 "ip link add $host type veth peer name $(nixcage_veth_cage_name builder)"
}

@test "deleting the pair deletes the host end, which takes the cage end with it" {
	run nixcage_veth_delete builder
	assert_success
	run ip_calls
	assert_output "ip link del $(nixcage_veth_host_name builder)"
}

@test "deleting the pair releases its pin before the link goes" {
	local host
	host="$(nixcage_veth_host_name builder)"
	stub_nft_listing "$host" 10.77.0.10
	run nixcage_veth_delete builder
	assert_success
	run cat "$CALLS"
	assert_line --index 0 "nft list set bridge nixcage placements"
	assert_line --index 1 "nft delete element bridge nixcage placements { \"$host\" . 10.77.0.10 }"
	assert_line --index 2 "ip link del $host"
}

@test "nspawn is handed the cage end under the name host0" {
	run nixcage_veth_nspawn_arg builder
	assert_output "--network-interface=$(nixcage_veth_cage_name builder):host0"
}

@test "a name outside the cage alphabet is refused before it reaches ip" {
	run nixcage_veth_make "../etc" fabriek-acme 10.77.0.10/24
	assert_failure
	[ ! -e "$CALLS" ]
}

# A microVM's port (ADR-019): a tap nixcage makes under the same host name,
# on the bridge, pinned and isolated the same, and handed to qemu by name
# through vmspawn's extra words, so the port exists before the guest boots.

@test "making the tap adds it under the host name, puts it on the bridge, pins, isolates and brings it up" {
	run nixcage_tap_make builder fabriek-acme 10.77.0.10/24
	assert_success
	local host
	host="$(nixcage_veth_host_name builder)"
	run ip_calls
	assert_line --index 0 "ip link show $host"
	assert_line --index 1 "ip tuntap add dev $host mode tap"
	assert_line --index 2 "ip link set $host master fabriek-acme"
	assert_line --index 3 "ip link set $host up"
	run grep -n "nft add element\|bridge link set\|ip link set $host up" "$CALLS"
	assert_line --index 0 --partial "nft add element bridge nixcage placements { \"$host\" . 10.77.0.10 }"
	assert_line --index 1 --partial "bridge link set dev $host isolated on"
	assert_line --index 2 --partial "ip link set $host up"
}

@test "a tap make without an address is refused as the pair's is" {
	run nixcage_tap_make builder fabriek-acme ""
	assert_failure
}

@test "deleting the tap releases its pin before the link goes" {
	local host
	host="$(nixcage_veth_host_name builder)"
	stub_nft_listing "$host" 10.77.0.10
	run nixcage_tap_delete builder
	assert_success
	run grep -n "nft delete element\|ip link del" "$CALLS"
	assert_line --index 0 --partial "nft delete element bridge nixcage placements { \"$host\" . 10.77.0.10 }"
	assert_line --index 1 --partial "ip link del $host"
}

@test "qemu is handed the tap by name, with no script to run on it, as one virtio interface" {
	run nixcage_tap_qemu_words builder
	assert_success
	local host
	host="$(nixcage_veth_host_name builder)"
	assert_line --index 0 "-netdev"
	assert_line --index 1 "tap,id=nixcage0,ifname=$host,script=no,downscript=no"
	assert_line --index 2 "-device"
	assert_line --index 3 "virtio-net-pci,netdev=nixcage0"
}
