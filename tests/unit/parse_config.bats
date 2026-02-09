#!/usr/bin/env bats
# Unit tests for parse_config() — TOML parser (Spec §4.1, §4.2)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "parse_config: reads default config values correctly" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	assert_equal "$CAGE_LEVEL" "standard"
	assert_equal "$CAGE_NET_ALLOW" "true"
	assert_equal "$CAGE_CPUS" "0"
	assert_equal "$CAGE_MEMORY" ""
	assert_equal "$CAGE_PURE" "true"
	assert_equal "$CAGE_STORE_MODE" "readonly"
	assert_equal "$CAGE_COMMAND" ""
}

@test "parse_config: parses sandbox level" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "strict"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "parse_config: parses relaxed sandbox level" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "relaxed"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "relaxed"
}

@test "parse_config: parses network allow=false" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.network]
allow = false
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_NET_ALLOW" "false"
}

@test "parse_config: parses resource limits" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.resources]
cpus = 4
memory = "8G"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_CPUS" "4"
	assert_equal "$CAGE_MEMORY" "8G"
}

@test "parse_config: parses packages array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
packages = ["python3", "git", "ripgrep"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_PACKAGES[0]}" "python3"
	assert_equal "${CAGE_PACKAGES[1]}" "git"
	assert_equal "${CAGE_PACKAGES[2]}" "ripgrep"
	assert_equal "${#CAGE_PACKAGES[@]}" "3"
}

@test "parse_config: parses single-element package array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
packages = ["git"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_PACKAGES[0]}" "git"
	assert_equal "${#CAGE_PACKAGES[@]}" "1"
}

@test "parse_config: parses nix pure=false" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
pure = false
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_PURE" "false"
}

@test "parse_config: parses store_mode" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
store_mode = "shared"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_STORE_MODE" "shared"
}

@test "parse_config: parses cage.command" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
command = "npx claude-code"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" "npx claude-code"
}

@test "parse_config: parses passthrough_env array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
passthrough_env = ["TERM", "HOME", "CUSTOM_VAR"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_PASSTHROUGH_ENV[0]}" "TERM"
	assert_equal "${CAGE_PASSTHROUGH_ENV[1]}" "HOME"
	assert_equal "${CAGE_PASSTHROUGH_ENV[2]}" "CUSTOM_VAR"
}

@test "parse_config: parses filesystem ro_bind array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
ro_bind = ["/opt/data", "~/docs"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_RO_BIND[0]}" "/opt/data"
	assert_equal "${CAGE_RO_BIND[1]}" "~/docs"
}

@test "parse_config: parses filesystem rw_bind array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
rw_bind = ["/tmp/shared"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_RW_BIND[0]}" "/tmp/shared"
}

@test "parse_config: parses filesystem blacklist array" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
blacklist = ["~/.ssh", "~/.aws"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_BLACKLIST[0]}" "~/.ssh"
	assert_equal "${CAGE_BLACKLIST[1]}" "~/.aws"
}

@test "parse_config: skips full-line comments" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
# This is a comment
[sandbox]
# Another comment
level = "strict"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "parse_config: skips empty lines" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'

[sandbox]

level = "strict"

TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "parse_config: preserves hash inside quoted values" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[cage]
command = "echo # not a comment"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_COMMAND" "echo # not a comment"
}

@test "parse_config: handles empty arrays" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
ro_bind = []
rw_bind = []
blacklist = []
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${#CAGE_RO_BIND[@]}" "0"
	assert_equal "${#CAGE_RW_BIND[@]}" "0"
	assert_equal "${#CAGE_BLACKLIST[@]}" "0"
}

@test "parse_config: exits with error for missing file" {
	run parse_config "$TEST_TEMP_DIR/nonexistent.toml"
	assert_failure
}

@test "parse_config: uses defaults for missing keys" {
	# Config with only one section — all other keys should use defaults
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "relaxed"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "relaxed"
	assert_equal "$CAGE_NET_ALLOW" "true"
	assert_equal "$CAGE_CPUS" "0"
	assert_equal "$CAGE_MEMORY" ""
	assert_equal "$CAGE_PURE" "true"
	assert_equal "$CAGE_STORE_MODE" "readonly"
}

@test "parse_config: handles whitespace around equals sign" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level   =   "strict"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_LEVEL" "strict"
}

@test "parse_config: complete config round-trip" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox]
level = "strict"

[sandbox.filesystem]
ro_bind = ["/opt/data"]
rw_bind = ["/tmp/work"]
blacklist = ["~/.ssh"]

[sandbox.network]
allow = false

[sandbox.resources]
cpus = 2
memory = "4G"

[nix]
packages = ["python3", "git"]
pure = false
store_mode = "copy"

[cage]
command = "python3 main.py"
passthrough_env = ["TERM", "CUSTOM"]
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	assert_equal "$CAGE_LEVEL" "strict"
	assert_equal "${CAGE_RO_BIND[0]}" "/opt/data"
	assert_equal "${CAGE_RW_BIND[0]}" "/tmp/work"
	assert_equal "${CAGE_BLACKLIST[0]}" "~/.ssh"
	assert_equal "$CAGE_NET_ALLOW" "false"
	assert_equal "$CAGE_CPUS" "2"
	assert_equal "$CAGE_MEMORY" "4G"
	assert_equal "${CAGE_PACKAGES[0]}" "python3"
	assert_equal "${CAGE_PACKAGES[1]}" "git"
	assert_equal "$CAGE_PURE" "false"
	assert_equal "$CAGE_STORE_MODE" "copy"
	assert_equal "$CAGE_COMMAND" "python3 main.py"
	assert_equal "${CAGE_PASSTHROUGH_ENV[0]}" "TERM"
	assert_equal "${CAGE_PASSTHROUGH_ENV[1]}" "CUSTOM"
}
