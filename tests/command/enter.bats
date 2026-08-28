#!/usr/bin/env bats
# enter validates the project before touching the VM

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "enter outside a flake directory fails" {
	mkdir -p "$TEST_TEMP_DIR/noflake"
	cd "$TEST_TEMP_DIR/noflake"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *flake.nix* ]]
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
