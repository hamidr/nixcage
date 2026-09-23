#!/usr/bin/env bats
# What a host declared, or the undeclared answer to it (ADR-023). One reader
# with two implementations, so an option added later has one place to say what
# it means where nothing was declared, and the suite can enumerate them.

load ../test_helper/common

setup() {
	setup_temp_dir
	CONFIG="$TEST_TEMP_DIR/container"
	source "$NIXCAGE_ROOT/modules/declaration.sh"
	unset NIXCAGE_DECLARED PRINCIPAL_UID_BASE STORAGE_DATASET
}

teardown() {
	teardown_temp_dir
}

@test "a rendered declaration is read into the environment" {
	cat >"$CONFIG" <<-EOF
		PRINCIPAL_UID_BASE=300000
		STORAGE_DATASET=tank/nixcage
	EOF
	nixcage_declaration_read "$CONFIG"
	[ "$PRINCIPAL_UID_BASE" = 300000 ]
	[ "$STORAGE_DATASET" = tank/nixcage ]
}

@test "a rendered declaration says it is declared" {
	: >"$CONFIG"
	nixcage_declaration_read "$CONFIG"
	[ -n "$NIXCAGE_DECLARED" ]
}

@test "no declaration is not a failure" {
	run nixcage_declaration_read "$CONFIG"
	[ "$status" -eq 0 ]
}

@test "no declaration leaves every setting it would carry unset" {
	nixcage_declaration_read "$CONFIG"
	[ -z "$NIXCAGE_DECLARED" ]
	[ -z "${PRINCIPAL_UID_BASE:-}" ]
	[ -z "${STORAGE_DATASET:-}" ]
}

# A second read of a declaration that has gone away must not keep answering
# from the first one: a host that was declared and is not any more is a host
# that declared nothing.
@test "a declaration that goes away stops being declared" {
	: >"$CONFIG"
	nixcage_declaration_read "$CONFIG"
	rm "$CONFIG"
	nixcage_declaration_read "$CONFIG"
	[ -z "$NIXCAGE_DECLARED" ]
}

@test "a verb that needs a declaration names the option that carries it" {
	run nixcage_declaration_refusal uid nixcage.principalUidRange
	[ "$status" -eq 0 ]
	[[ "$output" == *uid* ]]
	[[ "$output" == *nixcage.principalUidRange* ]]
	[[ "$output" == *nixosModules.host* ]]
}


# What a session is built from is the host's answer where it gave one (ADR-023
# decision 8). A caller that can run nixcage-container on a host whose sudoers
# grants it alone would otherwise choose the userland a root session is built
# from, on a machine whose administrator declared exactly that.

@test "an undeclared host takes the layer the caller named" {
	run nixcage_declaration_carried_flag "" /nix/store/a-profile "" 0
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "a declared host refuses a named layer" {
	run nixcage_declaration_carried_flag 1 /nix/store/a-profile "" 0
	assert_output --profile
}

@test "a declared host refuses a named guest" {
	run nixcage_declaration_carried_flag 1 "" /nix/store/a-system 0
	assert_output --guest
}

@test "a declared host refuses a named directory for vmspawn to search" {
	run nixcage_declaration_carried_flag 1 "" "" 2
	assert_output --microvm-path
}

@test "a declared host that was named nothing is not refused" {
	run nixcage_declaration_carried_flag 1 "" "" 0
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}
