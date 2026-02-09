#!/usr/bin/env bats
# Command tests for cmd_init (Spec §3.1, §7)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "init: creates nixcage.toml" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
}

@test "init: creates .envrc" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/.envrc" ]]
}

@test "init: creates .nixcage directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -d "$TEST_TEMP_DIR/.nixcage" ]]
}

@test "init: creates shell.nix" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/.nixcage/shell.nix" ]]
}

@test "init: creates profiles directory" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -d "$TEST_TEMP_DIR/.nixcage/profiles" ]]
}

@test "init: creates linux sandbox profile" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh" ]]
}

@test "init: creates all three macOS sandbox profiles" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-strict.sb" ]]
	[[ -f "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb" ]]
	[[ -f "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-relaxed.sb" ]]
}

@test "init: creates .gitignore in .nixcage" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/.nixcage/.gitignore" ]]
}

@test "init: .gitignore ignores resolved profile" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q "sandbox-macos-resolved.sb" "$TEST_TEMP_DIR/.nixcage/.gitignore"
	assert_success
}

@test "init: .gitignore ignores store directories" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q "store/" "$TEST_TEMP_DIR/.nixcage/.gitignore"
	assert_success
	run grep -q "isolated-store/" "$TEST_TEMP_DIR/.nixcage/.gitignore"
	assert_success
}

@test "init: fails if .nixcage already exists" {
	mkdir -p "$TEST_TEMP_DIR/.nixcage"
	run_nixcage init "$TEST_TEMP_DIR"
	assert_failure
	assert_output --partial "already initialized"
}

@test "init: defaults to current directory" {
	local subdir="$TEST_TEMP_DIR/project"
	mkdir -p "$subdir"
	cd "$subdir"

	run_nixcage init
	assert_success
	[[ -f "$subdir/nixcage.toml" ]]
	[[ -d "$subdir/.nixcage" ]]
}

@test "init: nixcage.toml has correct default values" {
	run_nixcage init "$TEST_TEMP_DIR"

	# Verify key defaults are in the generated config
	run grep -q 'level = "standard"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep -q 'allow = true' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep -q 'packages = \["nodejs_22"\]' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep -q 'pure = true' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep -q 'store_mode = "readonly"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

@test "init: .envrc evals nixcage _direnv_hook" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'eval "$(nixcage _direnv_hook)"' "$TEST_TEMP_DIR/.envrc"
	assert_success
}

@test "init: .envrc has fallback for missing nixcage" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'use nix .nixcage/shell.nix' "$TEST_TEMP_DIR/.envrc"
	assert_success
}

@test "init: shell.nix reads NIXCAGE_PACKAGES_JSON" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'NIXCAGE_PACKAGES_JSON' "$TEST_TEMP_DIR/.nixcage/shell.nix"
	assert_success
}

@test "init: shell.nix sets NIXCAGE_ACTIVE in shellHook" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'NIXCAGE_ACTIVE=1' "$TEST_TEMP_DIR/.nixcage/shell.nix"
	assert_success
}

@test "init: macOS standard profile has project dir placeholder" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'NIXCAGE_PROJECT_DIR' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"
	assert_success
}

@test "init: macOS relaxed profile has home dir placeholder" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'HOME_DIR' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-relaxed.sb"
	assert_success
}

@test "init: macOS strict profile has no network rules" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep 'allow network' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-strict.sb"
	assert_failure
}

@test "init: macOS standard profile has network rules" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'allow network-outbound' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"
	assert_success
	run grep -q 'allow network-inbound' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"
	assert_success
}

@test "init: linux profile defines build_bwrap_args function" {
	run_nixcage init "$TEST_TEMP_DIR"
	run grep -q 'build_bwrap_args()' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"
	assert_success
}

@test "init: all macOS profiles start with deny default" {
	run_nixcage init "$TEST_TEMP_DIR"
	for profile in strict standard relaxed; do
		run grep -q '(deny default)' "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-${profile}.sb"
		assert_success
	done
}

@test "init: prints success message" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "Initialized!"
}
