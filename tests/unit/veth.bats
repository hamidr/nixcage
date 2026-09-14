#!/usr/bin/env bats
# nixcage makes a cage's veth and names it (ADR-013): the names, the ip
# words that make and delete the pair, and the argument nspawn gets, driven
# with ip stubbed so nothing touches an interface.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/veth.sh
	source "$NIXCAGE_ROOT/modules/veth.sh"
	CALLS="$TEST_TEMP_DIR/ip.calls"
	mkdir -p "$TEST_TEMP_DIR/bin"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$CALLS" >"$TEST_TEMP_DIR/bin/ip"
	chmod +x "$TEST_TEMP_DIR/bin/ip"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
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
	run nixcage_veth_make builder fabriek-acme
	assert_success
	local host cage
	host="$(nixcage_veth_host_name builder)"
	cage="$(nixcage_veth_cage_name builder)"
	run cat "$CALLS"
	assert_line --index 0 "link add $host type veth peer name $cage"
	assert_line --index 1 "link set $host master fabriek-acme"
	assert_line --index 2 "link set $host up"
}

@test "deleting the pair deletes the host end, which takes the cage end with it" {
	run nixcage_veth_delete builder
	assert_success
	run cat "$CALLS"
	assert_output "link del $(nixcage_veth_host_name builder)"
}

@test "nspawn is handed the cage end under the name host0" {
	run nixcage_veth_nspawn_arg builder
	assert_output "--network-interface=$(nixcage_veth_cage_name builder):host0"
}

@test "a name outside the cage alphabet is refused before it reaches ip" {
	run nixcage_veth_make "../etc" fabriek-acme
	assert_failure
	[ ! -e "$CALLS" ]
}

# The host's rules are written at its build, where no verb can be asked, so
# the flake exports the same function of the name (ADR-013 point 3) and the
# two are held equal here.
@test "the flake's lib.vethHostName answers exactly what the shell answers" {
	local from_nix
	from_nix="$(nix eval --raw --impure --expr "(builtins.getFlake \"path:$NIXCAGE_ROOT\").lib.vethHostName \"a-cage-name-well-past-twelve-characters\"" 2>/dev/null)"
	[ -n "$from_nix" ]
	[ "$from_nix" = "$(nixcage_veth_host_name a-cage-name-well-past-twelve-characters)" ]
}
