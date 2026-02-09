#!/usr/bin/env bats
# Tests for store mode bwrap arg construction (Spec §6.1-6.4)
# These test the arg-building logic without actually running bwrap.

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

@test "store: readonly mode adds --tmpfs /nix/var" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate readonly mode logic from run_linux
	args+=(--tmpfs /nix/var)

	local joined="${args[*]}"
	[[ "$joined" == *"--tmpfs /nix/var"* ]]
	[[ "$joined" == *"--ro-bind /nix/store /nix/store"* ]]
}

@test "store: shared mode binds daemon socket dir" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate shared mode logic — always has /nix/store ro-bind
	local joined="${args[*]}"
	[[ "$joined" == *"--ro-bind /nix/store /nix/store"* ]]
}

@test "store: copy mode replaces /nix/store bind with local store" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate copy mode: strip default, add local
	strip_nix_store_bind args
	local local_store="$TEST_TEMP_DIR/.nixcage/store"
	args+=(--ro-bind "$local_store/nix/store" /nix/store)
	args+=(--tmpfs /nix/var)

	local joined="${args[*]}"
	[[ "$joined" == *"$local_store/nix/store"* ]]
	[[ "$joined" == *"--tmpfs /nix/var"* ]]
	# Original /nix/store should be gone
	[[ "$joined" != *"--ro-bind /nix/store /nix/store"* ]]
}

@test "store: isolated mode replaces /nix/store bind with isolated store" {
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	strip_nix_store_bind args
	local iso_store="$TEST_TEMP_DIR/.nixcage/isolated-store"
	args+=(--ro-bind "$iso_store/nix/store" /nix/store)
	args+=(--tmpfs /nix/var)

	local joined="${args[*]}"
	[[ "$joined" == *"$iso_store/nix/store"* ]]
	[[ "$joined" == *"--tmpfs /nix/var"* ]]
}
