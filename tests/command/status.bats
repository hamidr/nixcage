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

@test "status on macOS prints the SSH key the config flake has to list" {
	run_nixcage status
	[ "$status" -eq 0 ]
	[ -f "$XDG_STATE_HOME/nixcage/id_ed25519.pub" ]
	[[ "$output" == *"$(cut -d' ' -f1-2 "$XDG_STATE_HOME/nixcage/id_ed25519.pub")"* ]]
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
