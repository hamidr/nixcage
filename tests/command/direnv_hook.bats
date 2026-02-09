#!/usr/bin/env bats
# Command tests for cmd_direnv_hook (Spec §8)

setup() {
	load '../test_helper/common'
	setup_temp_dir

	# Set up a valid cage project
	run_nixcage init "$TEST_TEMP_DIR"
}

teardown() {
	teardown_temp_dir
}

@test "direnv_hook: exports NIXCAGE_ACTIVE=1" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'export NIXCAGE_ACTIVE=1'
}

@test "direnv_hook: exports NIXCAGE_ROOT" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "export NIXCAGE_ROOT="
}

@test "direnv_hook: exports NIXCAGE_LEVEL" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'export NIXCAGE_LEVEL="standard"'
}

@test "direnv_hook: exports NIXCAGE_OS" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'export NIXCAGE_OS='
}

@test "direnv_hook: defines cage() alias" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'cage()'
}

@test "direnv_hook: defines cagerun() alias" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'cagerun()'
}

@test "direnv_hook: prints activation message" {
	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "Cage active:"
}

@test "direnv_hook: output is valid shell code" {
	cd "$TEST_TEMP_DIR"
	local hook_output
	hook_output="$(bash "$NIXCAGE_BIN" _direnv_hook)"

	# The output should be eval-safe bash
	run bash -n <(echo "$hook_output")
	assert_success
}

@test "direnv_hook: reflects config level" {
	# Change level to strict
	sed -i.bak 's/level = "standard"/level = "strict"/' "$TEST_TEMP_DIR/nixcage.toml"

	cd "$TEST_TEMP_DIR"
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'NIXCAGE_LEVEL="strict"'
}
