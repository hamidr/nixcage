#!/usr/bin/env bats
# Tests for config validation (items 4-6)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "validation: invalid sandbox level exits with error" {
	run_nixcage init "$TEST_TEMP_DIR"

	# Set an invalid level
	sed -i.bak 's/level = "standard"/level = "foobar"/' "$TEST_TEMP_DIR/nixcage.toml"

	cd "$TEST_TEMP_DIR"
	run_nixcage run echo hello
	assert_failure
	assert_output --partial "Invalid sandbox level"
	assert_output --partial "foobar"
}

@test "validation: strict level is accepted" {
	run_nixcage init "$TEST_TEMP_DIR"
	sed -i.bak 's/level = "standard"/level = "strict"/' "$TEST_TEMP_DIR/nixcage.toml"

	cd "$TEST_TEMP_DIR"
	# Should not fail on level validation (will fail on nix-shell, that's ok)
	run_nixcage status
	assert_success
	assert_output --partial "strict"
}

@test "validation: relaxed level is accepted" {
	run_nixcage init "$TEST_TEMP_DIR"
	sed -i.bak 's/level = "standard"/level = "relaxed"/' "$TEST_TEMP_DIR/nixcage.toml"

	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "relaxed"
}

@test "validation: version command lists version in help" {
	run_nixcage help
	assert_success
	assert_output --partial "version"
}
