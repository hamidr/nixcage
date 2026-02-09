#!/usr/bin/env bats
# Unit tests for warn_macos_unsupported() — blacklist and resource limit warnings

setup() {
	load '../test_helper/common'
	source_nixcage
}

@test "warn_macos_unsupported: blacklist items produce warning" {
	local bl=("~/.ssh" "~/.aws")

	run warn_macos_unsupported bl "0" ""
	[[ "$output" == *"blacklist is not supported on macOS"* ]]
}

@test "warn_macos_unsupported: empty blacklist produces no warning" {
	local bl=()

	run warn_macos_unsupported bl "0" ""
	[[ "$output" != *"blacklist"* ]]
}

@test "warn_macos_unsupported: non-zero cpus produce warning" {
	local bl=()

	run warn_macos_unsupported bl "4" ""
	[[ "$output" == *"Resource limits (cpus/memory) are not available on macOS"* ]]
}

@test "warn_macos_unsupported: non-empty memory produces warning" {
	local bl=()

	run warn_macos_unsupported bl "0" "4G"
	[[ "$output" == *"Resource limits (cpus/memory) are not available on macOS"* ]]
}

@test "warn_macos_unsupported: defaults produce no warning" {
	local bl=()

	run warn_macos_unsupported bl "0" ""
	assert_equal "$output" ""
}
