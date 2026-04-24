#!/usr/bin/env bats
# Command tests for CLI dispatch and top-level routing

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "help: exits 0" {
	run_nixcage help
	assert_success
}

@test "--help: exits 0" {
	run_nixcage --help
	assert_success
}

@test "version: prints nixcage 1.0.0" {
	run_nixcage version
	assert_success
	assert_output "nixcage 1.0.0"
}

@test "--version: prints nixcage 1.0.0" {
	run_nixcage --version
	assert_success
	assert_output "nixcage 1.0.0"
}

@test "unknown-command: exits 1" {
	run_nixcage unknown-command
	assert_failure
}

@test "unknown-command: prints error message" {
	run_nixcage unknown-command
	assert_failure
	assert_output --partial "Unknown command"
}

@test "build: exits 1 outside VM project" {
	cd "$TEST_TEMP_DIR"
	run_nixcage build
	assert_failure
	assert_output --partial "nixcage.vm.nix"
}

@test "start: exits 1 outside VM project" {
	cd "$TEST_TEMP_DIR"
	run_nixcage start
	assert_failure
	assert_output --partial "nixcage.vm.nix"
}

@test "shell: exits 1 outside VM project" {
	cd "$TEST_TEMP_DIR"
	run_nixcage shell
	assert_failure
	assert_output --partial "nixcage.vm.nix"
}

@test "run: exits 1 outside VM project" {
	cd "$TEST_TEMP_DIR"
	run_nixcage run foo
	assert_failure
	assert_output --partial "nixcage.vm.nix"
}

@test "status: exits 1 outside VM project" {
	cd "$TEST_TEMP_DIR"
	run_nixcage status
	assert_failure
}
