#!/usr/bin/env bats
# User Story: "As a security-conscious developer, I use strict mode to block home/network"
# Validates: Spec §5.1 (level matrix), §5.2 (Linux bwrap), §5.3 (macOS Seatbelt)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: strict level parsed correctly from config" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "strict"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "story: strict linux profile uses tmpfs home and unshare-net" {
	# Given a strict config and the linux profile
	run_nixcage init "$TEST_TEMP_DIR"

	# Source the linux profile to test build_bwrap_args
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "strict" args

	local joined="${args[*]}"

	# Should have tmpfs home (no real home access)
	[[ "$joined" == *"--tmpfs /home"* ]]

	# Should unshare network
	[[ "$joined" == *"--unshare-net"* ]]

	# Should NOT have --share-net
	[[ "$joined" != *"--share-net"* ]]

	# Should NOT bind project dir (strict = no project dir access)
	[[ "$joined" != *"--bind $TEST_TEMP_DIR"* ]]
}

@test "story: standard linux profile shares network and binds project" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	local joined="${args[*]}"

	[[ "$joined" == *"--share-net"* ]]
	[[ "$joined" == *"--bind $TEST_TEMP_DIR $TEST_TEMP_DIR"* ]]
	[[ "$joined" == *"--tmpfs /home"* ]]
}

@test "story: relaxed linux profile gives read-only home and network" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "relaxed" args

	local joined="${args[*]}"

	[[ "$joined" == *"--ro-bind $HOME $HOME"* ]]
	[[ "$joined" == *"--share-net"* ]]
	[[ "$joined" == *"--bind $TEST_TEMP_DIR $TEST_TEMP_DIR"* ]]
}

@test "story: all linux levels mount /nix/store read-only" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	for level in strict standard relaxed; do
		local args=()
		build_bwrap_args "$TEST_TEMP_DIR" "$level" args

		local joined="${args[*]}"
		[[ "$joined" == *"--ro-bind /nix/store /nix/store"* ]]
	done
}

@test "story: all linux levels mount /proc and /dev" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	for level in strict standard relaxed; do
		local args=()
		build_bwrap_args "$TEST_TEMP_DIR" "$level" args

		local joined="${args[*]}"
		[[ "$joined" == *"--proc /proc"* ]]
		[[ "$joined" == *"--dev /dev"* ]]
		[[ "$joined" == *"--tmpfs /tmp"* ]]
	done
}

@test "story: all linux levels set chdir to project dir" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	for level in strict standard relaxed; do
		local args=()
		build_bwrap_args "$TEST_TEMP_DIR" "$level" args

		local joined="${args[*]}"
		[[ "$joined" == *"--chdir $TEST_TEMP_DIR"* ]]
	done
}

@test "story: macOS strict profile has no network allow rules" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-strict.sb"

	run grep 'allow network' "$profile"
	assert_failure
}

@test "story: macOS strict profile reads /nix but not home" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-strict.sb"

	# Can read /nix
	run grep -q '(subpath "/nix")' "$profile"
	assert_success

	# Cannot read HOME_DIR (no HOME_DIR placeholder in strict)
	run grep 'HOME_DIR' "$profile"
	assert_failure
}
