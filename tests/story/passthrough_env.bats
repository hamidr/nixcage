#!/usr/bin/env bats
# User Story: "As a developer, I use passthrough_env to forward API keys safely"
# Validates: Spec §4.2 [cage], §10.3 (injection prevention)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: default passthrough includes TERM, LANG, ANTHROPIC_API_KEY" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	assert_equal "${CAGE_PASSTHROUGH_ENV[0]}" "TERM"
	assert_equal "${CAGE_PASSTHROUGH_ENV[1]}" "LANG"
	assert_equal "${CAGE_PASSTHROUGH_ENV[2]}" "ANTHROPIC_API_KEY"
}

@test "story: developer adds custom env vars to passthrough" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
passthrough_env = ["TERM", "LANG", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN"]
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${#CAGE_PASSTHROUGH_ENV[@]}" "5"
	assert_equal "${CAGE_PASSTHROUGH_ENV[3]}" "OPENAI_API_KEY"
	assert_equal "${CAGE_PASSTHROUGH_ENV[4]}" "GITHUB_TOKEN"
}

@test "story: escape_sq prevents single-quote injection in env values" {
	# Simulate a malicious API key value
	local malicious_value="key'; rm -rf /; echo '"
	local escaped
	escaped="$(escape_sq "$malicious_value")"

	# The escaped value is safe: when embedded inside single quotes and eval'd,
	# it produces the original value without executing injected commands
	local recovered
	recovered="$(eval "printf '%s' '${escaped}'")"
	assert_equal "$recovered" "$malicious_value"
}

@test "story: escape_sq handles env values with special chars" {
	local value="sk-ant-api03-abc123_XYZ+/=="
	local escaped
	escaped="$(escape_sq "$value")"

	# No single quotes in this value, should pass through unchanged
	assert_equal "$escaped" "$value"
}

@test "story: escape_sq round-trips values containing single quotes" {
	local original="it's a test 'value' here"
	local escaped
	escaped="$(escape_sq "$original")"

	local recovered
	recovered="$(eval "printf '%s' '${escaped}'")"
	assert_equal "$recovered" "$original"
}
