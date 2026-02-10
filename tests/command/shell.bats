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

@test "shell: --debug flag does not break dispatch" {
	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"
	run_nixcage shell --debug
	refute_output --partial "No nixcage.toml found"
	refute_output --partial "Unknown command"
}

@test "shell: --debug with explicit dir works" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage shell --debug "$TEST_TEMP_DIR"
	refute_output --partial "No nixcage.toml found"
}

@test "shell: --debug without cage still fails" {
	local empty_dir="$TEST_TEMP_DIR/empty"
	mkdir -p "$empty_dir"
	run_nixcage shell --debug "$empty_dir"
	assert_failure
	assert_output --partial "No nixcage.toml found"
}
