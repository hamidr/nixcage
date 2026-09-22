#!/usr/bin/env bats
# enter validates the project before touching the VM

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

# A directory under a workspace root is a project whether or not it declares
# a flake (ADR-021), so enter validates the root and nothing about the flake.
@test "enter in a directory with no flake.nix gets past validation" {
	write_cache 22022 "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/src/noflake"
	cd "$TEST_TEMP_DIR/src/noflake"
	run_nixcage enter
	[[ "$output" != *flake.nix* ]]
}

@test "enter outside every workspace root fails without a flake too" {
	write_cache 22022 "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/elsewhere/noflake"
	cd "$TEST_TEMP_DIR/elsewhere/noflake"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

@test "enter outside every workspace root fails before starting the VM" {
	write_cache 22022 "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/elsewhere/proj"
	touch "$TEST_TEMP_DIR/elsewhere/proj/flake.nix"
	cd "$TEST_TEMP_DIR/elsewhere/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

@test "enter without a built VM fails with rebuild guidance" {
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *rebuild* ]]
}
