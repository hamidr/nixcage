#!/usr/bin/env bats
# Tests for strip_macos_network_rules() — network rule stripping via helper

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage

	# Generate sandbox profile templates via init
	run_nixcage init "$TEST_TEMP_DIR"
}

teardown() {
	teardown_temp_dir
}

@test "network override: standard profile has network rules before stripping" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "standard")"

	run grep -c 'allow network' "$resolved"
	assert_success
	# Standard has both outbound and inbound
	[[ "$output" -ge 2 ]]
}

@test "network override: stripping removes all network rules" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "standard")"

	strip_macos_network_rules "$resolved"

	run grep 'allow network' "$resolved"
	assert_failure
}

@test "network override: other rules preserved after stripping" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "standard")"

	strip_macos_network_rules "$resolved"

	# Core rules should still be present
	run grep -q 'deny default' "$resolved"
	assert_success
	run grep -q 'allow process-exec' "$resolved"
	assert_success
	run grep -q 'allow file-read' "$resolved"
	assert_success
}

@test "network override: strict profile has no network rules to strip" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "strict")"

	local before
	before="$(cat "$resolved")"

	strip_macos_network_rules "$resolved"

	local after
	after="$(cat "$resolved")"
	assert_equal "$after" "$before"
}
