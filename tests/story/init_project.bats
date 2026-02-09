#!/usr/bin/env bats
# User Story: "As a developer, I init a project and get a working scaffold"
# Validates: Spec §3.1 (init command), §7 (generated files), §7.1 (shell.nix), §7.2 (.envrc)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

# ── Scenario: Developer initializes a new project ──

@test "story: developer creates a new cage from scratch" {
	# Given a fresh project directory
	local project="$TEST_TEMP_DIR/my-project"
	mkdir -p "$project"

	# When I initialize nixcage
	run_nixcage init "$project"
	assert_success

	# Then I get a complete scaffold with all required files (Spec §7)
	[[ -f "$project/nixcage.toml" ]]
	[[ -f "$project/.envrc" ]]
	[[ -f "$project/.nixcage/shell.nix" ]]
	[[ -f "$project/.nixcage/.gitignore" ]]
	[[ -d "$project/.nixcage/profiles" ]]
	[[ -f "$project/.nixcage/profiles/sandbox-linux.sh" ]]
	[[ -f "$project/.nixcage/profiles/sandbox-macos-strict.sb" ]]
	[[ -f "$project/.nixcage/profiles/sandbox-macos-standard.sb" ]]
	[[ -f "$project/.nixcage/profiles/sandbox-macos-relaxed.sb" ]]
}

@test "story: scaffold is ready for direnv activation" {
	# Given I init a project
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	# Then .envrc should eval the direnv hook
	run grep -q 'eval "$(nixcage _direnv_hook)"' "$TEST_TEMP_DIR/.envrc"
	assert_success

	# And it should have a fallback for when nixcage is not installed
	run grep -q 'use nix .nixcage/shell.nix' "$TEST_TEMP_DIR/.envrc"
	assert_success
}

@test "story: scaffold has sensible secure defaults" {
	# Given I init a project
	run_nixcage init "$TEST_TEMP_DIR"

	# Then the default config should be "standard" level (balanced security)
	run grep -q 'level = "standard"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success

	# And store should be readonly by default (can't install new packages in cage)
	run grep -q 'store_mode = "readonly"' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success

	# And nix-shell should run in pure mode by default
	run grep -q 'pure = true' "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

@test "story: shell.nix correctly consumes package JSON" {
	# Given I init a project
	run_nixcage init "$TEST_TEMP_DIR"

	# Then shell.nix should read packages from NIXCAGE_PACKAGES_JSON env var
	run grep -q 'builtins.fromJSON (builtins.getEnv "NIXCAGE_PACKAGES_JSON")' "$TEST_TEMP_DIR/.nixcage/shell.nix"
	assert_success

	# And it should set NIXCAGE_ACTIVE in the shell hook
	run grep -q 'export NIXCAGE_ACTIVE=1' "$TEST_TEMP_DIR/.nixcage/shell.nix"
	assert_success
}

# ── Scenario: Developer tries to init an already-initialized project ──

@test "story: init is idempotent-safe (refuses to overwrite)" {
	# Given I already initialized a project
	run_nixcage init "$TEST_TEMP_DIR"
	assert_success

	# And I added custom content to the config
	echo "# my custom note" >>"$TEST_TEMP_DIR/nixcage.toml"

	# When I try to init again
	run_nixcage init "$TEST_TEMP_DIR"

	# Then it should refuse
	assert_failure
	assert_output --partial "already initialized"

	# And my custom content should be preserved
	run grep -q "my custom note" "$TEST_TEMP_DIR/nixcage.toml"
	assert_success
}

# ── Scenario: Generated profiles match security spec ──

@test "story: all macOS profiles start with deny-by-default" {
	run_nixcage init "$TEST_TEMP_DIR"

	for level in strict standard relaxed; do
		local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-${level}.sb"

		# First non-comment, non-version line should be deny default
		run grep -q '(deny default)' "$profile"
		assert_success
	done
}

@test "story: all macOS profiles have base permissions for sandbox-exec" {
	run_nixcage init "$TEST_TEMP_DIR"

	# These three permissions are required for sandbox-exec to run
	# /bin/bash -c "..." without silently aborting (exit 134).
	for level in strict standard relaxed; do
		local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-${level}.sb"

		# Shebang script execution
		run grep -q '(allow process-exec-interpreter)' "$profile"
		assert_success

		# Terminal I/O (ioctl on /dev/tty)
		run grep -q '(allow file-ioctl)' "$profile"
		assert_success

		# Root directory read for path traversal
		run grep -q '(literal "/")' "$profile"
		assert_success
	done
}

@test "story: strict profile denies network" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-strict.sb"

	# Should NOT have any network allow rules
	run grep 'allow network' "$profile"
	assert_failure
}

@test "story: standard profile allows network and project dir writes" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"

	# Should allow network
	run grep -q 'allow network-outbound' "$profile"
	assert_success

	# Should allow project dir writes (using placeholder)
	run grep -q 'NIXCAGE_PROJECT_DIR' "$profile"
	assert_success
}

@test "story: relaxed profile allows reading real home" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-relaxed.sb"

	# Should allow reading home (using placeholder)
	run grep -q 'HOME_DIR' "$profile"
	assert_success
}

@test "story: linux profile creates correct namespace isolation" {
	run_nixcage init "$TEST_TEMP_DIR"
	local profile="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	# Should unshare PID, UTS, IPC namespaces
	run grep -q 'unshare-pid' "$profile"
	assert_success
	run grep -q 'unshare-uts' "$profile"
	assert_success
	run grep -q 'unshare-ipc' "$profile"
	assert_success
	run grep -q 'die-with-parent' "$profile"
	assert_success
}
