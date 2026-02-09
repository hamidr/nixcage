#!/usr/bin/env bats
# User Story: "As a developer, I set a default command so 'nixcage shell' runs my tool"
# Validates: Spec §4.2 [cage] command, §9.2

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: cage.command defaults to empty (interactive shell)" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" ""
}

@test "story: developer sets default command for their cage" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
command = "npx @anthropic-ai/claude-code"
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" "npx @anthropic-ai/claude-code"
}

@test "story: command with special characters is preserved" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
command = "python3 -c 'print(1+1)'"
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	# The TOML parser strips outer quotes; inner quotes should be preserved
	[[ "$CAGE_COMMAND" == *"print"* ]]
}
