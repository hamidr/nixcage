#!/usr/bin/env bats
# Command tests for run argument parsing (dir -- cmd syntax)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "run: bare command uses auto-detected project dir" {
	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"
	# run_sandboxed will fail (no nix-shell), but we verify it found the cage
	run_nixcage run echo hello
	# Should NOT say "No nixcage.toml found"
	refute_output --partial "No nixcage.toml found"
}

@test "run: dir -- cmd uses explicit directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	# Run from a different directory, pointing at the cage
	run_nixcage run "$TEST_TEMP_DIR" -- echo hello
	refute_output --partial "No nixcage.toml found"
}

@test "run: -- cmd without dir uses auto-detection" {
	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"
	run_nixcage run -- echo hello
	refute_output --partial "No nixcage.toml found"
}

@test "run: dir -- with no cmd enters default command" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage run "$TEST_TEMP_DIR" --
	refute_output --partial "No nixcage.toml found"
}

@test "run: invalid dir -- cmd fails" {
	run_nixcage run /nonexistent/path -- echo hello
	assert_failure
}

@test "run: dir without cage -- cmd fails" {
	local empty_dir="$TEST_TEMP_DIR/empty"
	mkdir -p "$empty_dir"
	run_nixcage run "$empty_dir" -- echo hello
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "run: --debug flag is parsed and stripped" {
	# Test that --debug is extracted without running the sandbox
	source "$NIXCAGE_BIN"
	NIXCAGE_DEBUG=false

	# Mock run_sandboxed to capture what it receives
	run_sandboxed() { echo "project_dir=$1 cmd=${*:2}"; }

	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"

	# Call cmd_run with --debug
	run cmd_run --debug echo hello

	# Verify --debug was stripped (not passed to run_sandboxed as part of cmd)
	refute_output --partial -- "--debug"
	assert_output --partial "echo hello"
}

@test "run: --debug is stripped before directory parsing" {
	run_nixcage run --debug /nonexistent/path -- echo hello
	assert_failure
	# --debug should not appear as part of the directory path error
	refute_output --partial -- "--debug"
}

@test "run: --debug with dir -- cmd parses correctly" {
	source "$NIXCAGE_BIN"

	# Mock run_sandboxed to capture arguments
	run_sandboxed() { echo "project_dir=$1 cmd=${*:2}"; }

	run_nixcage init "$TEST_TEMP_DIR"

	run cmd_run --debug "$TEST_TEMP_DIR" -- echo hello
	assert_output --partial "project_dir=$TEST_TEMP_DIR"
	assert_output --partial "cmd=echo hello"
}
