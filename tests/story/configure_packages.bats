#!/usr/bin/env bats
# User Story: "As a developer, I configure packages so my tools have the right dependencies"
# Validates: Spec §4.2 [nix], §7.1 (shell.nix)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: developer configures multiple packages" {
	# Given a config with multiple packages
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
packages = ["python3", "git", "ripgrep", "nodejs_22"]
TOML

	# When config is parsed
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	# Then all packages are available
	assert_equal "${#CAGE_PACKAGES[@]}" "4"
	assert_equal "${CAGE_PACKAGES[0]}" "python3"
	assert_equal "${CAGE_PACKAGES[1]}" "git"
	assert_equal "${CAGE_PACKAGES[2]}" "ripgrep"
	assert_equal "${CAGE_PACKAGES[3]}" "nodejs_22"
}

@test "story: developer uses impure nix-shell for system access" {
	# Given a config with pure=false
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
packages = ["nodejs_22"]
pure = false
TOML

	# When config is parsed
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	# Then pure mode is disabled
	assert_equal "$CAGE_PURE" "false"
}

@test "story: developer changes store mode for full isolation" {
	# Given a config with isolated store
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
packages = ["nodejs_22"]
store_mode = "isolated"
TOML

	# When config is parsed
	parse_config "$TEST_TEMP_DIR/nixcage.toml"

	# Then store mode is set
	assert_equal "$CAGE_STORE_MODE" "isolated"
}

@test "story: developer configures shared store for speed" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[nix]
store_mode = "shared"
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_STORE_MODE" "shared"
}

@test "story: default package list includes nodejs" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_PACKAGES[0]}" "nodejs_22"
}
