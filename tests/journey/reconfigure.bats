#!/usr/bin/env bats
# User Journey: Reconfigure an existing project
# init → edit config → reinit → verify changes → status

setup() {
	load '../test_helper/common'
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "journey: reconfigure project with reinit" {
	local project="$TEST_TEMP_DIR/my-app"
	mkdir -p "$project"

	# Step 1: Initialize with defaults
	run_nixcage init "$project"
	assert_success

	# Step 2: Verify initial state
	cd "$project"
	run_nixcage status
	assert_output --partial "standard"

	# Step 3: Developer realizes they need strict isolation
	# (reinit regenerates all files with fresh defaults)
	run_nixcage reinit "$project"
	assert_success

	# Step 4: Modify the fresh config to strict
	sed -i.bak 's/level = "standard"/level = "strict"/' "$project/nixcage.toml"

	# Step 5: Verify the change took effect
	run_nixcage status
	assert_output --partial "strict"

	# Step 6: Profiles were regenerated (not stale)
	[[ -f "$project/.nixcage/profiles/sandbox-linux.sh" ]]
	[[ -f "$project/.nixcage/profiles/sandbox-macos-strict.sb" ]]
}

@test "journey: edit config values and verify parsing" {
	local project="$TEST_TEMP_DIR/my-app"
	mkdir -p "$project"

	# Step 1: Init with defaults
	run_nixcage init "$project"
	assert_success

	# Step 2: Developer customizes everything
	cat >"$project/nixcage.toml" <<'TOML'
[sandbox]
level = "strict"

[sandbox.filesystem]
ro_bind = ["/opt/shared"]
rw_bind = []
blacklist = ["~/.ssh", "~/.aws"]

[sandbox.network]
allow = false

[sandbox.resources]
cpus = 2
memory = "4G"

[nix]
packages = ["python3", "git"]
pure = false
store_mode = "shared"

[cage]
command = "python3 app.py"
passthrough_env = ["TERM", "DATABASE_URL"]
TOML

	# Step 3: Status reflects the new config
	cd "$project"
	run_nixcage status
	assert_success
	assert_output --partial "strict"
	assert_output --partial "shared"
	assert_output --partial "false"
	assert_output --partial "python3"

	# Step 4: direnv hook reflects the config
	run_nixcage _direnv_hook
	assert_success
	assert_output --partial 'NIXCAGE_LEVEL="strict"'
}

@test "journey: reinit preserves directory but resets profiles" {
	local project="$TEST_TEMP_DIR/my-app"
	mkdir -p "$project"

	# Init and add a custom file in .nixcage
	run_nixcage init "$project"
	assert_success

	# Add some project files
	touch "$project/app.py"
	touch "$project/requirements.txt"

	# Reinit
	run_nixcage reinit "$project"
	assert_success

	# Project files are preserved
	[[ -f "$project/app.py" ]]
	[[ -f "$project/requirements.txt" ]]

	# nixcage files are regenerated
	[[ -f "$project/nixcage.toml" ]]
	[[ -f "$project/.envrc" ]]
	[[ -d "$project/.nixcage" ]]
}
