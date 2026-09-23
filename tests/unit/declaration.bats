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
