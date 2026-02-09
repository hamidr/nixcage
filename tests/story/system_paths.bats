#!/usr/bin/env bats
# Tests for system path mounting in bwrap args (Spec §5.1, §5.2)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"
}

teardown() {
	teardown_temp_dir
}

@test "system paths: /etc/resolv.conf is mounted read-only" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	[[ "$joined" == *"--ro-bind /etc/resolv.conf /etc/resolv.conf"* ]]
}

@test "system paths: /etc/nix is mounted if it exists" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	if [[ -d /etc/nix ]]; then
		[[ "$joined" == *"--ro-bind /etc/nix /etc/nix"* ]]
	fi
}

@test "system paths: /etc/ssl is mounted if it exists" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	if [[ -d /etc/ssl ]]; then
		[[ "$joined" == *"--ro-bind /etc/ssl /etc/ssl"* ]]
	fi
}

@test "system paths: /proc is mounted" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	[[ "$joined" == *"--proc /proc"* ]]
}

@test "system paths: /dev is mounted" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	[[ "$joined" == *"--dev /dev"* ]]
}

@test "system paths: /tmp is tmpfs" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args
	local joined="${args[*]}"
	[[ "$joined" == *"--tmpfs /tmp"* ]]
}
