#!/usr/bin/env bats
# User Journey: Error paths and recovery
# Tests graceful handling of misuse, missing files, and edge cases

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "journey: developer tries init twice, gets helpful error" {
	# Step 1: Init succeeds
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	# Step 2: Init again fails with guidance
	run_nixcage init "$TEST_TEMP_DIR"
	assert_failure
	assert_output --partial "already initialized"
	assert_output --partial "reinit"
}

@test "journey: developer destroys then re-initializes cleanly" {
	# Step 1: Init
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	# Step 2: Destroy
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success

	# Step 3: Re-init works (no leftover state)
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
}

@test "journey: developer uses wrong command, gets help" {
	run_nixcage frobnicate
	assert_failure
	assert_output --partial "Unknown command"
	assert_output --partial "Usage:"
}

@test "journey: commands that need a cage fail outside a cage" {
	cd "$TEST_TEMP_DIR"

	# Each cage-requiring command should fail gracefully
	run_nixcage run echo test
	assert_failure

	run_nixcage shell
	assert_failure

	run_nixcage status
	assert_failure
}

@test "journey: direnv hook degrades gracefully outside cage" {
	cd "$TEST_TEMP_DIR"

	# _direnv_hook should not crash — it outputs a warning message
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "Not in a nixcage project"
}

@test "journey: destroy on empty directory is a no-op" {
	run_nixcage destroy "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "No nixcage found"
}

@test "journey: status finds cage from subdirectory" {
	# Init at top level
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	# Check status from a subdirectory
	mkdir -p "$TEST_TEMP_DIR/src/components/deep"
	cd "$TEST_TEMP_DIR/src/components/deep"

	run_nixcage status
	assert_success
	assert_output --partial "standard"
}

@test "journey: direnv hook finds cage from subdirectory" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	mkdir -p "$TEST_TEMP_DIR/src/lib"
	cd "$TEST_TEMP_DIR/src/lib"

	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "NIXCAGE_ACTIVE=1"
}

@test "journey: help is always available regardless of context" {
	# Help should work from anywhere, no cage needed
	cd "$TEST_TEMP_DIR"

	run_nixcage help
	assert_success
	assert_output --partial "Usage:"

	run_nixcage --help
	assert_success

	run_nixcage -h
	assert_success
}

@test "journey: version is always available regardless of context" {
	cd "$TEST_TEMP_DIR"

	run_nixcage version
	assert_success
	assert_output --partial "nixcage"

	run_nixcage --version
	assert_success
}
