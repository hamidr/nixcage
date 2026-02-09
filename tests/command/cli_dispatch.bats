#!/usr/bin/env bats
# Command tests for CLI dispatch and error handling (Spec §3.1, §3.3)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "unknown command: exits with error" {
	run_nixcage foobar
	assert_failure
	assert_output --partial "Unknown command: foobar"
}

@test "unknown command: shows help after error" {
	run_nixcage nonexistent
	assert_failure
	assert_output --partial "Usage:"
}

@test "run outside project: exits with error" {
	cd "$TEST_TEMP_DIR"
	run_nixcage run echo hello
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "shell outside project: exits with error" {
	cd "$TEST_TEMP_DIR"
	run_nixcage shell
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "status outside project: exits with error" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_failure
}

@test "_direnv_hook outside project: prints error message (not crash)" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "Not in a nixcage project"
}
