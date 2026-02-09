#!/usr/bin/env bats
# Command tests for cmd_status (Spec §3.1)

setup() {
	load '../test_helper/common'
	setup_temp_dir

	run_nixcage init "$TEST_TEMP_DIR"
}

teardown() {
	teardown_temp_dir
}

@test "status: prints project directory" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Project:"
}

@test "status: prints OS" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "OS:"
}

@test "status: prints sandbox level" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Level:"
	assert_output --partial "standard"
}

@test "status: prints store mode" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Store:"
	assert_output --partial "readonly"
}

@test "status: prints network status" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Network:"
	assert_output --partial "true"
}

@test "status: prints packages" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Packages:"
	assert_output --partial "nodejs_22"
}

@test "status: checks dependencies" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "Dependencies:"
}

@test "status: checks for jq" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "jq"
}

@test "status: reflects changed config" {
	sed -i.bak 's/level = "standard"/level = "strict"/' "$TEST_TEMP_DIR/nixcage.toml"

	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_success
	assert_output --partial "strict"
}
