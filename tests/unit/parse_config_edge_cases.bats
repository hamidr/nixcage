#!/usr/bin/env bats
# Edge case tests for parse_config() — inline comments, spaces in arrays, validation

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

# ── Inline comment stripping ──

@test "parse_config: strips inline comment after quoted value" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "strict" # this is a comment
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "parse_config: strips inline comment after unquoted boolean" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.network]
allow = false # disable network
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_NET_ALLOW" "false"
}

@test "parse_config: strips inline comment after unquoted integer" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.resources]
cpus = 4 # limit to 4 cores
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_CPUS" "4"
}

@test "parse_config: preserves hash inside double-quoted value" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
command = "echo #tag"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" "echo #tag"
}

@test "parse_config: preserves hash inside single-quoted value" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<TOML
[cage]
command = 'echo #tag'
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" "echo #tag"
}

@test "parse_config: strips inline comment after quoted memory value" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.resources]
memory = "4G" # max 4 gigs
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_MEMORY" "4G"
}

# ── Array values with spaces ──

@test "parse_config: handles paths with spaces in array values" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
ro_bind = ["/path/with spaces", "/another path/here"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${#CAGE_RO_BIND[@]}" "2"
	assert_equal "${CAGE_RO_BIND[0]}" "/path/with spaces"
	assert_equal "${CAGE_RO_BIND[1]}" "/another path/here"
}

@test "parse_config: handles single path with spaces in array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
ro_bind = ["/my path"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${#CAGE_RO_BIND[@]}" "1"
	assert_equal "${CAGE_RO_BIND[0]}" "/my path"
}

# ── TOML key pattern ──

@test "parse_config: ignores keys with uppercase letters" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
Level = "strict"
level = "relaxed"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	# Only lowercase key should be parsed
	assert_equal "$CAGE_LEVEL" "relaxed"
}
