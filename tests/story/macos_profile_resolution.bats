#!/usr/bin/env bats
# Tests for resolve_macos_profile() — level selection and placeholder resolution

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

@test "resolve_macos_profile: standard selects standard template" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "standard")"

	# Should contain content from the standard template (has network rules)
	run grep -q 'allow network-outbound' "$resolved"
	assert_success
}

@test "resolve_macos_profile: strict selects strict template" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "strict")"

	# Strict has no network rules
	run grep 'allow network' "$resolved"
	assert_failure
}

@test "resolve_macos_profile: relaxed selects relaxed template" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "relaxed")"

	# Relaxed template allows reading home dir
	run grep -q "$HOME" "$resolved"
	assert_success
}

@test "resolve_macos_profile: replaces NIXCAGE_PROJECT_DIR placeholder" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "standard")"

	# Placeholder should be gone, actual path should be present
	run grep 'NIXCAGE_PROJECT_DIR' "$resolved"
	assert_failure
	run grep -qF "$TEST_TEMP_DIR" "$resolved"
	assert_success
}

@test "resolve_macos_profile: replaces HOME_DIR placeholder" {
	local resolved
	resolved="$(resolve_macos_profile "$TEST_TEMP_DIR" "relaxed")"

	# Relaxed template uses HOME_DIR — should be resolved
	run grep 'HOME_DIR' "$resolved"
	assert_failure
	run grep -qF "$HOME" "$resolved"
	assert_success
}

@test "resolve_macos_profile: invalid level returns error" {
	run resolve_macos_profile "$TEST_TEMP_DIR" "nonexistent"
	assert_failure
}
