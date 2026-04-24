#!/usr/bin/env bats
# Unit tests for find_vm_root()

setup() {
  load '../test_helper/common'
  setup_temp_dir
  source_nixcage
}

teardown() {
  teardown_temp_dir
}

@test "find_vm_root: finds nixcage.vm.nix in current directory" {
  touch "$TEST_TEMP_DIR/nixcage.vm.nix"
  cd "$TEST_TEMP_DIR"
  result="$(find_vm_root)"
  assert_equal "$result" "$TEST_TEMP_DIR"
}

@test "find_vm_root: finds nixcage.vm.nix in parent directory" {
  touch "$TEST_TEMP_DIR/nixcage.vm.nix"
  mkdir -p "$TEST_TEMP_DIR/subdir"
  cd "$TEST_TEMP_DIR/subdir"
  result="$(find_vm_root)"
  assert_equal "$result" "$TEST_TEMP_DIR"
}

@test "find_vm_root: errors when not found" {
  cd "$TEST_TEMP_DIR"
  run find_vm_root
  assert_failure
  assert_output --partial "No nixcage.vm.nix found"
}
