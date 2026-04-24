#!/usr/bin/env bats
# Command tests for cmd_status

setup() {
	load '../test_helper/common'
	setup_temp_dir
	run_nixcage init "$TEST_TEMP_DIR"
}

teardown() {
	teardown_temp_dir
}

@test "status: shows project path" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Project:"
	assert_output --partial "$TEST_TEMP_DIR"
}

@test "status: shows Built: no when result symlink absent" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Built:      no"
}

@test "status: shows Running: no when pid file absent" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Running:    no"
}
