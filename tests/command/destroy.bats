#!/usr/bin/env bats
# Command tests for cmd_destroy

setup() {
  load '../test_helper/common'
  setup_temp_dir
}

teardown() {
  teardown_temp_dir
}

@test "destroy: removes nixcage.vm.nix" {
  run_nixcage init "$TEST_TEMP_DIR"
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  [[ ! -f "$TEST_TEMP_DIR/nixcage.vm.nix" ]]
}

@test "destroy: removes .nixcage-vm directory" {
  run_nixcage init "$TEST_TEMP_DIR"
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  [[ ! -d "$TEST_TEMP_DIR/.nixcage-vm" ]]
}

@test "destroy: strips .nixcage-vm/ from root .gitignore" {
  run_nixcage init "$TEST_TEMP_DIR"
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  run grep -xF '.nixcage-vm/' "$TEST_TEMP_DIR/.gitignore"
  assert_failure
}

@test "destroy: leaves other .gitignore content intact" {
  echo 'node_modules/' >"$TEST_TEMP_DIR/.gitignore"
  run_nixcage init "$TEST_TEMP_DIR"
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  grep -qxF 'node_modules/' "$TEST_TEMP_DIR/.gitignore"
}

@test "destroy: prints success message" {
  run_nixcage init "$TEST_TEMP_DIR"
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  assert_output --partial "Removed"
}

@test "destroy: warns when no nixcage files found" {
  run_nixcage destroy "$TEST_TEMP_DIR"
  assert_success
  assert_output --partial "No nixcage files found"
}
