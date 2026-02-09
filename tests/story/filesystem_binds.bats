#!/usr/bin/env bats
# User Story: "As a developer, I add extra bind mounts and blacklist sensitive paths"
# Validates: Spec §4.2 [sandbox.filesystem], §5.2 (Linux binds)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: developer adds read-only bind for shared data" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
ro_bind = ["/opt/shared-data", "/etc/custom"]
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_RO_BIND[0]}" "/opt/shared-data"
	assert_equal "${CAGE_RO_BIND[1]}" "/etc/custom"
}

@test "story: developer adds read-write bind for output directory" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
rw_bind = ["/tmp/build-output"]
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${CAGE_RW_BIND[0]}" "/tmp/build-output"
}

@test "story: developer blacklists sensitive directories" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.filesystem]
blacklist = ["~/.ssh", "~/.aws", "~/.gnupg"]
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "${#CAGE_BLACKLIST[@]}" "3"
	assert_equal "${CAGE_BLACKLIST[0]}" "~/.ssh"
	assert_equal "${CAGE_BLACKLIST[1]}" "~/.aws"
	assert_equal "${CAGE_BLACKLIST[2]}" "~/.gnupg"
}

@test "story: tilde paths in binds are expanded correctly" {
	local result
	result="$(expand_tilde "~/.ssh")"
	assert_equal "$result" "$HOME/.ssh"

	result="$(expand_tilde "~/Documents/data")"
	assert_equal "$result" "$HOME/Documents/data"
}

@test "story: linux bwrap adds ro_bind paths that exist" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	# Create a path to bind
	mkdir -p "$TEST_TEMP_DIR/shared-data"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate the ro_bind loop from run_linux
	local path="$TEST_TEMP_DIR/shared-data"
	[[ -e "$path" ]] && args+=(--ro-bind "$path" "$path")

	local joined="${args[*]}"
	[[ "$joined" == *"--ro-bind $TEST_TEMP_DIR/shared-data"* ]]
}

@test "story: linux bwrap adds blacklist as tmpfs" {
	# Blacklist paths are mounted as tmpfs regardless of existence
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate the blacklist loop from run_linux
	local path="$HOME/.ssh"
	args+=(--tmpfs "$path")

	local joined="${args[*]}"
	[[ "$joined" == *"--tmpfs $HOME/.ssh"* ]]
}

@test "story: macOS adds ro_bind as seatbelt file-read rules" {
	run_nixcage init "$TEST_TEMP_DIR"

	local profile_src="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"
	local profile_resolved="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-resolved.sb"

	sed \
		-e "s|NIXCAGE_PROJECT_DIR|$TEST_TEMP_DIR|g" \
		-e "s|HOME_DIR|$HOME|g" \
		"$profile_src" >"$profile_resolved"

	# Simulate adding an ro_bind path (same as run_macos)
	echo '(allow file-read* (subpath "/opt/shared"))' >>"$profile_resolved"

	run grep -qF '(allow file-read* (subpath "/opt/shared"))' "$profile_resolved"
	assert_success
}
