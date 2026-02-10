#!/usr/bin/env bats
# Command tests for shell directory argument

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "shell: no arg uses auto-detected project dir" {
	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"
	run_nixcage shell
	refute_output --partial "No nixcage.toml found"
}

@test "shell: explicit dir uses that directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage shell "$TEST_TEMP_DIR"
	refute_output --partial "No nixcage.toml found"
}

@test "shell: invalid dir fails" {
	run_nixcage shell /nonexistent/path
	assert_failure
}

@test "shell: dir without cage fails" {
	local empty_dir="$TEST_TEMP_DIR/empty"
	mkdir -p "$empty_dir"
	run_nixcage shell "$empty_dir"
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "shell: --debug flag is parsed and stripped" {
	# Test that --debug is extracted without running the sandbox
	source "$NIXCAGE_BIN"

	# Mock run_sandboxed to capture what it receives
	run_sandboxed() { echo "project_dir=$1"; }

	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"

	run cmd_shell --debug
	# Verify it found the cage and called run_sandboxed
	assert_output --partial "project_dir=$TEST_TEMP_DIR"
}

@test "shell: --debug with explicit dir parses correctly" {
	source "$NIXCAGE_BIN"

	# Mock run_sandboxed
	run_sandboxed() { echo "project_dir=$1"; }

	run_nixcage init "$TEST_TEMP_DIR"

	run cmd_shell --debug "$TEST_TEMP_DIR"
	assert_output --partial "project_dir=$TEST_TEMP_DIR"
}

@test "shell: --debug without cage still fails" {
	local empty_dir="$TEST_TEMP_DIR/empty"
	mkdir -p "$empty_dir"
	run_nixcage shell --debug "$empty_dir"
	assert_failure
	assert_output --partial "No nixcage.toml found"
}
