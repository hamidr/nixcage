#!/usr/bin/env bats
# status reports without requiring a built or running VM

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "status with no state reports not built and not running" {
	run_nixcage status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Built:        no"* ]]
	[[ "$output" == *"Running:      no"* ]]
}

@test "status shows cached port and roots when built" {
	write_cache 23456 "/home/me/Src"
	touch "$XDG_STATE_HOME/nixcage/result"
	run_nixcage status
	[ "$status" -eq 0 ]
	[[ "$output" == *23456* ]]
	[[ "$output" == *"/home/me/Src"* ]]
}

@test "status names the config flake in use" {
	run_nixcage status
	[[ "$output" == *"$NIXCAGE_FLAKE"* ]]
}
