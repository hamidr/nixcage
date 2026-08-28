#!/usr/bin/env bats
# Top-level CLI dispatch: help, version, flake selection, unknown commands

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "no arguments shows help" {
	run_nixcage
	[ "$status" -eq 0 ]
	[[ "$output" == *Usage:* ]]
}

@test "help lists exactly the five commands" {
	run_nixcage help
	[ "$status" -eq 0 ]
	for cmd in enter down rebuild rm status; do
		[[ "$output" == *"$cmd"* ]]
	done
	[[ "$output" != *install-hook* ]]
	[[ "$output" != *init* ]]
	[[ "$output" != *sync* ]]
}

@test "version prints the version" {
	run_nixcage version
	[ "$status" -eq 0 ]
	[[ "$output" == "nixcage "* ]]
}

@test "unknown command fails with help" {
	run_nixcage frobnicate
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command"* ]]
}

@test "--flake without an argument fails" {
	run_nixcage --flake
	[ "$status" -ne 0 ]
	[[ "$output" == *"--flake requires"* ]]
}

@test "rebuild with a missing path flake fails with template guidance" {
	run_nixcage --flake "$TEST_TEMP_DIR/nonexistent" rebuild
	[ "$status" -ne 0 ]
	[[ "$output" == *"flake new"* ]]
}
