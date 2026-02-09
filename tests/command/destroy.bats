#!/usr/bin/env bats
# Command tests for cmd_destroy (Spec §3.1)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "destroy: removes .nixcage directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	[[ ! -d "$TEST_TEMP_DIR/.nixcage" ]]
}

@test "destroy: removes nixcage.toml" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	[[ ! -f "$TEST_TEMP_DIR/nixcage.toml" ]]
}

@test "destroy: removes .envrc" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	[[ ! -f "$TEST_TEMP_DIR/.envrc" ]]
}

@test "destroy: preserves other files in directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	touch "$TEST_TEMP_DIR/my-project-file.js"

	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/my-project-file.js" ]]
}

@test "destroy: warns when no cage found" {
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "No nixcage found"
}

@test "destroy: prints success message" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_output --partial "Removed all nixcage files"
}
