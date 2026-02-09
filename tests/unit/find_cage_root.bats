#!/usr/bin/env bats
# Unit tests for find_cage_root() (Spec §3.2)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "find_cage_root: finds nixcage.toml in current directory" {
	touch "$TEST_TEMP_DIR/nixcage.toml"
	cd "$TEST_TEMP_DIR"

	result="$(find_cage_root)"
	assert_equal "$result" "$TEST_TEMP_DIR"
}

@test "find_cage_root: finds nixcage.toml in parent directory" {
	touch "$TEST_TEMP_DIR/nixcage.toml"
	mkdir -p "$TEST_TEMP_DIR/sub/deep"
	cd "$TEST_TEMP_DIR/sub/deep"

	result="$(find_cage_root)"
	assert_equal "$result" "$TEST_TEMP_DIR"
}

@test "find_cage_root: finds nixcage.toml one level up" {
	touch "$TEST_TEMP_DIR/nixcage.toml"
	mkdir -p "$TEST_TEMP_DIR/child"
	cd "$TEST_TEMP_DIR/child"

	result="$(find_cage_root)"
	assert_equal "$result" "$TEST_TEMP_DIR"
}

@test "find_cage_root: exits with error when no nixcage.toml found" {
	mkdir -p "$TEST_TEMP_DIR/empty"
	cd "$TEST_TEMP_DIR/empty"

	run find_cage_root
	assert_failure
	assert_output --partial "No nixcage.toml found"
}

@test "find_cage_root: finds closest nixcage.toml when nested" {
	# Parent has a config
	touch "$TEST_TEMP_DIR/nixcage.toml"
	# Child also has a config
	mkdir -p "$TEST_TEMP_DIR/child"
	touch "$TEST_TEMP_DIR/child/nixcage.toml"
	cd "$TEST_TEMP_DIR/child"

	result="$(find_cage_root)"
	assert_equal "$result" "$TEST_TEMP_DIR/child"
}
