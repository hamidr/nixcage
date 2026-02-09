#!/usr/bin/env bats
# Unit tests for strip_nix_store_bind()

setup() {
	load '../test_helper/common'
	source_nixcage
}

@test "strip_nix_store_bind: removes --ro-bind /nix/store /nix/store triplet" {
	local args=(--unshare-pid --ro-bind /nix/store /nix/store --tmpfs /tmp)
	strip_nix_store_bind args

	local joined="${args[*]}"
	# All three tokens should be removed
	[[ "$joined" != *"/nix/store"* ]]
	[[ "$joined" != *"--ro-bind"* ]]
	[[ "$joined" == *"--unshare-pid"* ]]
	[[ "$joined" == *"--tmpfs"* ]]
}

@test "strip_nix_store_bind: preserves other --ro-bind entries" {
	local args=(--unshare-pid --ro-bind /nix/store /nix/store --ro-bind /etc/ssl /etc/ssl --tmpfs /tmp)
	strip_nix_store_bind args

	local joined="${args[*]}"
	[[ "$joined" != *"/nix/store"* ]]
	[[ "$joined" == *"/etc/ssl"* ]]
	[[ "$joined" == *"--ro-bind"* ]]
}

@test "strip_nix_store_bind: no-op when /nix/store not present" {
	local args=(--unshare-pid --tmpfs /tmp --dev /dev)
	local original="${args[*]}"
	strip_nix_store_bind args
	assert_equal "${args[*]}" "$original"
}

@test "strip_nix_store_bind: handles empty array" {
	local args=()
	strip_nix_store_bind args
	assert_equal "${#args[@]}" "0"
}

@test "strip_nix_store_bind: handles /nix/store at start of array" {
	local args=(--ro-bind /nix/store /nix/store --tmpfs /tmp)
	strip_nix_store_bind args

	local joined="${args[*]}"
	[[ "$joined" != *"/nix/store"* ]]
	assert_equal "${args[*]}" "--tmpfs /tmp"
}
