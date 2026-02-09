#!/usr/bin/env bats
# Tests for append_macos_bind_rules() — filesystem bind rule appending

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage

	# Create a minimal seatbelt profile to append rules to
	cat >"$TEST_TEMP_DIR/profile.sb" <<'SB'
(version 1)
(deny default)
(allow process-exec)
SB
}

teardown() {
	teardown_temp_dir
}

@test "append_macos_bind_rules: ro_bind appends file-read rule" {
	mkdir -p "$TEST_TEMP_DIR/shared"
	local ro=("$TEST_TEMP_DIR/shared")
	local rw=()

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	run grep -qF "(allow file-read* (subpath \"$TEST_TEMP_DIR/shared\"))" "$TEST_TEMP_DIR/profile.sb"
	assert_success
}

@test "append_macos_bind_rules: rw_bind appends file-read and file-write rule" {
	mkdir -p "$TEST_TEMP_DIR/output"
	local ro=()
	local rw=("$TEST_TEMP_DIR/output")

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	run grep -qF "(allow file-read* file-write* (subpath \"$TEST_TEMP_DIR/output\"))" "$TEST_TEMP_DIR/profile.sb"
	assert_success
}

@test "append_macos_bind_rules: nonexistent path is skipped" {
	local ro=("/nonexistent/path/that/does/not/exist")
	local rw=()

	local before
	before="$(cat "$TEST_TEMP_DIR/profile.sb")"

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	local after
	after="$(cat "$TEST_TEMP_DIR/profile.sb")"
	assert_equal "$after" "$before"
}

@test "append_macos_bind_rules: tilde is expanded" {
	# HOME always exists, so this should produce a rule
	local ro=("~")
	local rw=()

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	run grep -qF "(allow file-read* (subpath \"$HOME\"))" "$TEST_TEMP_DIR/profile.sb"
	assert_success
}

@test "append_macos_bind_rules: multiple paths all appear" {
	mkdir -p "$TEST_TEMP_DIR/dir1"
	mkdir -p "$TEST_TEMP_DIR/dir2"
	local ro=("$TEST_TEMP_DIR/dir1" "$TEST_TEMP_DIR/dir2")
	local rw=()

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	run grep -cF "allow file-read*" "$TEST_TEMP_DIR/profile.sb"
	assert_success
	# Should have 2 lines appended (plus possibly existing ones)
	[[ "$output" -ge 2 ]]
}

@test "append_macos_bind_rules: empty arrays produce no rules" {
	local ro=()
	local rw=()

	local before
	before="$(cat "$TEST_TEMP_DIR/profile.sb")"

	append_macos_bind_rules "$TEST_TEMP_DIR/profile.sb" ro rw

	local after
	after="$(cat "$TEST_TEMP_DIR/profile.sb")"
	assert_equal "$after" "$before"
}
