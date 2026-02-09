#!/usr/bin/env bats
# User Journey: Happy path lifecycle
# init → configure → status → direnv hook → destroy
# Tests the complete lifecycle WITHOUT requiring nix or sandbox (those are external deps)

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "journey: complete project lifecycle" {
	local project="$TEST_TEMP_DIR/my-app"
	mkdir -p "$project"

	# Step 1: Initialize — developer sets up a new sandboxed project
	run_nixcage init "$project"
	assert_success
	assert_output --partial "Initialized!"
	[[ -f "$project/nixcage.toml" ]]
	[[ -f "$project/.envrc" ]]
	[[ -d "$project/.nixcage" ]]

	# Step 2: Verify status — developer checks everything is configured
	cd "$project"
	run_nixcage status
	assert_success
	assert_output --partial "standard"
	assert_output --partial "readonly"
	assert_output --partial "nodejs_22"

	# Step 3: direnv hook — developer activates the environment
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial "NIXCAGE_ACTIVE=1"
	assert_output --partial "Cage active:"

	# Step 4: Hook output is valid shell — developer can safely eval it
	local hook_output
	hook_output="$(bash "$NIXCAGE_BIN" _direnv_hook)"
	run bash -n <(echo "$hook_output")
	assert_success

	# Step 5: Destroy — developer cleans up
	run_nixcage destroy "$project"
	assert_success
	assert_output --partial "Removed all nixcage files"
	[[ ! -d "$project/.nixcage" ]]
	[[ ! -f "$project/nixcage.toml" ]]
	[[ ! -f "$project/.envrc" ]]

	# The project directory itself still exists
	[[ -d "$project" ]]
}

@test "journey: init then immediate run outside project fails gracefully" {
	local project="$TEST_TEMP_DIR/my-app"
	mkdir -p "$project"

	# Init in one directory
	run_nixcage init "$project"
	assert_success

	# Try to run from a different directory (not inside the project)
	cd "$TEST_TEMP_DIR"
	mkdir -p "$TEST_TEMP_DIR/elsewhere"
	cd "$TEST_TEMP_DIR/elsewhere"

	run_nixcage run echo hello
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "journey: multiple projects coexist independently" {
	local project_a="$TEST_TEMP_DIR/project-a"
	local project_b="$TEST_TEMP_DIR/project-b"
	mkdir -p "$project_a" "$project_b"

	# Init both
	run_nixcage init "$project_a"
	assert_success
	run_nixcage init "$project_b"
	assert_success

	# Modify project A's config
	sed -i.bak 's/level = "standard"/level = "strict"/' "$project_a/nixcage.toml"

	# Verify they have independent configs
	cd "$project_a"
	run_nixcage status
	assert_output --partial "strict"

	cd "$project_b"
	run_nixcage status
	assert_output --partial "standard"

	# Destroy one without affecting the other
	run_nixcage destroy "$project_a"
	assert_success
	[[ ! -d "$project_a/.nixcage" ]]
	[[ -d "$project_b/.nixcage" ]]
}
