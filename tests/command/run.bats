#!/usr/bin/env bats
# Command tests for cmd_run

setup() {
  load '../test_helper/common'
  setup_temp_dir
}

teardown() {
  teardown_temp_dir
}

@test "run: requires at least one argument" {
  run_nixcage run
  assert_failure
  assert_output --partial "Usage"
}

@test "run: errors with VM not built when no result symlink" {
  # init creates the project but does not build the VM image
  run_nixcage init "$TEST_TEMP_DIR"
  cd "$TEST_TEMP_DIR"
  run_nixcage run echo hello
  assert_failure
  assert_output --partial "not built"
}
