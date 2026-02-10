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

@test "run: --debug flag does not break dispatch" {
	run_nixcage init "$TEST_TEMP_DIR"
	cd "$TEST_TEMP_DIR"
	run_nixcage run --debug echo hello
	refute_output --partial "No nixcage.toml found"
	refute_output --partial "Unknown command"
}

@test "run: --debug is stripped before command parsing" {
	run_nixcage run --debug /nonexistent/path -- echo hello
	assert_failure
	# --debug should not appear as part of the directory path
	refute_output --partial -- "--debug"
}

@test "run: --debug with dir -- cmd syntax works" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage run --debug "$TEST_TEMP_DIR" -- echo hello
	refute_output --partial "No nixcage.toml found"
}
