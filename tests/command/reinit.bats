#!/usr/bin/env bats
# Command tests for cmd_reinit (Spec §3.1)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "reinit: works on existing cage" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	run_nixcage reinit "$TEST_TEMP_DIR"
	assert_success
	[[ -d "$TEST_TEMP_DIR/.nixcage" ]]
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
}

@test "reinit: overwrites nixcage.toml with defaults" {
	run_nixcage init "$TEST_TEMP_DIR"

	# Modify the config
	echo 'extra_key = "value"' >>"$TEST_TEMP_DIR/nixcage.toml"

	run_nixcage reinit "$TEST_TEMP_DIR"
	assert_success

	# The extra key should be gone
	run grep -q 'extra_key' "$TEST_TEMP_DIR/nixcage.toml"
	assert_failure
}

@test "reinit: regenerates profiles" {
	run_nixcage init "$TEST_TEMP_DIR"

	# Modify a profile
	echo "# modified" >>"$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	run_nixcage reinit "$TEST_TEMP_DIR"
	assert_success

	# The modification should be gone
	run grep -q '# modified' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"
	assert_failure
}

@test "reinit: works even when no prior cage exists" {
	run_nixcage reinit "$TEST_TEMP_DIR"
	assert_success
	[[ -d "$TEST_TEMP_DIR/.nixcage" ]]
}

@test "reinit: prints removal message when overwriting" {
	run_nixcage init "$TEST_TEMP_DIR"
	run_nixcage reinit "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "Removed existing .nixcage directory"
}
