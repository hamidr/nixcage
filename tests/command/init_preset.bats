#!/usr/bin/env bats
# Tests for cmd_init --preset flag

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

# ── Success cases ──

@test "init --preset claude-code: creates all files" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
	[[ -f "$TEST_TEMP_DIR/.envrc" ]]
	[[ -d "$TEST_TEMP_DIR/.nixcage" ]]
	[[ -f "$TEST_TEMP_DIR/.nixcage/shell.nix" ]]
}

@test "init --preset claude-code: config has claude-code in packages" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep 'packages' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial 'claude-code'
	assert_output --partial 'nodejs_22'
}

@test "init --preset claude-code: config has ~/.claude in rw_bind" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep 'rw_bind' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial '~/.claude'
}

@test "init --preset claude-code: config has ~/.ssh in ro_bind" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep 'ro_bind' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial '~/.ssh'
}

@test "init --preset claude-code: config has ~/.gitconfig in ro_bind" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep 'ro_bind' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial '~/.gitconfig'
}

@test "init --preset claude-code: config has SSH_AUTH_SOCK in passthrough_env" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep 'passthrough_env' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial 'SSH_AUTH_SOCK'
}

@test "init --preset claude-code: config has pure = false" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep -q 'pure = false' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

@test "init --preset claude-code: config has standard level" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep -q 'level = "standard"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

@test "init --preset claude-code: shows preset-specific next steps" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "nixcage run"
}

@test "init --preset claude-code: config has command = claude-code" {
	run_nixcage init --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep -q 'command = "claude"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

# ── Equals syntax ──

@test "init --preset=claude-code: works with equals syntax" {
	run_nixcage init --preset=claude-code "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
	run grep -q 'pure = false' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

# ── Error cases ──

@test "init --preset unknown: fails with error" {
	run_nixcage init --preset unknown "$TEST_TEMP_DIR"
	assert_failure
	assert_output --partial "Unknown preset: 'unknown'"
	assert_output --partial "list-presets"
}

@test "init --preset without value: fails with error" {
	run_nixcage init --preset
	assert_failure
	assert_output --partial "--preset requires a value"
}

@test "init with unknown option: fails with error" {
	run_nixcage init --bogus "$TEST_TEMP_DIR"
	assert_failure
	assert_output --partial "Unknown option"
}

# ── Default regression ──

@test "init without --preset: still produces default config" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	run grep -q 'pure = true' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep -q 'packages = \["nodejs_22"\]' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

@test "init without --preset: shows generic next steps" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success
	assert_output --partial "Edit"
	assert_output --partial "nixcage.toml"
}

# ── reinit forwarding ──

@test "reinit --preset claude-code: forwards preset to init" {
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	run_nixcage reinit --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	run grep -q 'pure = false' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
	run grep 'packages' "$TEST_TEMP_DIR/nixcage.toml"
	assert_output --partial 'claude-code'
}

@test "reinit --preset claude-code: works on fresh directory" {
	run_nixcage reinit --preset claude-code "$TEST_TEMP_DIR"
	assert_success
	[[ -f "$TEST_TEMP_DIR/nixcage.toml" ]]
	run grep -q 'pure = false' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}
