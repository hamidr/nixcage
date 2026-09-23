#!/usr/bin/env bats
# What a host declared, or the undeclared answer to it (ADR-023). One reader
# with two implementations, so an option added later has one place to say what
# it means where nothing was declared, and the suite can enumerate them.

load ../test_helper/common

setup() {
	setup_temp_dir
	CONFIG="$TEST_TEMP_DIR/old-container"
	source "$NIXCAGE_ROOT/modules/declaration.sh"
	unset NIXCAGE_DECLARED PRINCIPAL_UID_BASE STORAGE_DATASET
}

teardown() {
	teardown_temp_dir
}

@test "a rendered declaration is read into the environment" {
	cat >"$CONFIG" <<-EOF
		DECLARATION_VERSION=1
		PRINCIPAL_UID_BASE=300000
		STORAGE_DATASET=tank/nixcage
	EOF
	nixcage_declaration_read "$CONFIG"
	[ "$PRINCIPAL_UID_BASE" = 300000 ]
	[ "$STORAGE_DATASET" = tank/nixcage ]
}

@test "a rendered declaration says it is declared" {
	echo DECLARATION_VERSION=1 >"$CONFIG"
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
	echo DECLARATION_VERSION=1 >"$CONFIG"
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


# One file, one reader, and a version (ADR-024). The keys are what the two
# modules rendered across four files before this, so what changes is where
# they are read from and what an unreadable one means.

write_declaration() {
	cat >"$CONFIG"
}

@test "a declaration this nixcage renders is read whole" {
	write_declaration <<-EOF
		DECLARATION_VERSION=1
		WORKSPACE_ROOTS=/srv:/home/me/Src
		PRINCIPAL_UID_BASE=700000
		SECRET_ENV="ANTHROPIC_API_KEY=anthropic TOKEN=gh"
		GIT_USER_NAME="Ada Lovelace"
		GIT_USER_EMAIL=ada@example.org
	EOF
	nixcage_declaration_read "$CONFIG"
	[ -n "$NIXCAGE_DECLARED" ]
	[ "$WORKSPACE_ROOTS" = /srv:/home/me/Src ]
	[ "$PRINCIPAL_UID_BASE" = 700000 ]
	[ "$SECRET_ENV" = "ANTHROPIC_API_KEY=anthropic TOKEN=gh" ]
	[ "$GIT_USER_NAME" = "Ada Lovelace" ]
}

# A setting a declaration does not mention reads as unset, whatever a reader
# before it left behind: the undeclared value of every key is stated in one
# place rather than inherited from the last host that was read.
@test "a key the declaration omits is not the last one's" {
	write_declaration <<-EOF
		DECLARATION_VERSION=1
		STORAGE_DATASET=tank/nixcage
	EOF
	nixcage_declaration_read "$CONFIG"
	write_declaration <<-EOF
		DECLARATION_VERSION=1
		WORKSPACE_ROOTS=/srv
	EOF
	nixcage_declaration_read "$CONFIG"
	[ -z "$STORAGE_DATASET" ]
	[ "$WORKSPACE_ROOTS" = /srv ]
}

# A host that declared workspace roots must never read as a host that
# declared nothing, which is what a version-blind reader does the first time
# the format changes.
@test "a declaration from a newer nixcage is refused, not taken as absent" {
	write_declaration <<-EOF
		DECLARATION_VERSION=99
		WORKSPACE_ROOTS=/srv
	EOF
	run nixcage_declaration_read "$CONFIG"
	[ "$status" -eq 2 ]
	[[ "$output" == *99* ]]
	[[ "$output" == *"$NIXCAGE_DECLARATION_VERSION"* ]]
}

@test "a declaration with no version at all is refused the same way" {
	write_declaration <<-EOF
		WORKSPACE_ROOTS=/srv
	EOF
	run nixcage_declaration_read "$CONFIG"
	[ "$status" -eq 2 ]
}

# What a partial upgrade leaves: a CLI newer than the module it stands on
# (ADR-024 decision 7). Removed one release after it lands.
@test "the files an older nixcage rendered are read, and say they are old" {
	echo "WORKSPACE_ROOTS=/srv" >"$TEST_TEMP_DIR/old-config"
	cat >"$TEST_TEMP_DIR/old-container" <<-EOF
		PRINCIPAL_UID_BASE=700000
		STORAGE_DATASET=tank/nixcage
	EOF
	nixcage_declaration_read_legacy "$TEST_TEMP_DIR/old-config" "$TEST_TEMP_DIR/old-container"
	[ -n "$NIXCAGE_DECLARED" ]
	[ -n "$NIXCAGE_DECLARATION_LEGACY" ]
	[ "$WORKSPACE_ROOTS" = /srv ]
	[ "$PRINCIPAL_UID_BASE" = 700000 ]
}

@test "a host with neither file declared nothing" {
	nixcage_declaration_read_legacy "$TEST_TEMP_DIR/gone" "$TEST_TEMP_DIR/also-gone"
	[ -z "$NIXCAGE_DECLARED" ]
	[ -z "$NIXCAGE_DECLARATION_LEGACY" ]
}

# Secrets are a word list now rather than a file of their own: a secret's
# name and a variable's name are both checked elsewhere and neither can hold
# a space.
@test "the secret pairs a declaration names are read one per line" {
	write_declaration <<-EOF
		DECLARATION_VERSION=1
		SECRET_ENV="KEY=anthropic TOKEN=gh"
	EOF
	nixcage_declaration_read "$CONFIG"
	run nixcage_declaration_secret_pairs
	assert_line --index 0 "KEY=anthropic"
	assert_line --index 1 "TOKEN=gh"
}

@test "a declaration that names no secret has none" {
	write_declaration <<-EOF
		DECLARATION_VERSION=1
	EOF
	nixcage_declaration_read "$CONFIG"
	run nixcage_declaration_secret_pairs
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}
