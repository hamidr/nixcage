#!/usr/bin/env bats
# Command tests for cmd_install_hook

setup() {
  load '../test_helper/common'
  setup_temp_dir
  # Point HOME at the temp dir so we don't touch the real rc files
  export HOME="$TEST_TEMP_DIR"
  export SHELL=""
}

teardown() {
  teardown_temp_dir
}

@test "install-hook: appends hook block to rc file (zsh)" {
  SHELL="/bin/zsh"
  touch "$TEST_TEMP_DIR/.zshrc"
  run bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  assert_success
  run grep -q "nixcage-hook-begin" "$TEST_TEMP_DIR/.zshrc"
  assert_success
}

@test "install-hook: appends hook block to rc file (bash)" {
  SHELL="/bin/bash"
  touch "$TEST_TEMP_DIR/.bashrc"
  run bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/bash bash '$NIXCAGE_BIN' install-hook"
  assert_success
  run grep -q "nixcage-hook-begin" "$TEST_TEMP_DIR/.bashrc"
  assert_success
}

@test "install-hook: is idempotent (second run does not duplicate block)" {
  touch "$TEST_TEMP_DIR/.zshrc"
  bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  local count
  count="$(grep -c "nixcage-hook-begin" "$TEST_TEMP_DIR/.zshrc")"
  assert_equal "$count" "1"
}

@test "install-hook --remove: strips the block" {
  touch "$TEST_TEMP_DIR/.zshrc"
  bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  run bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh '$NIXCAGE_BIN' install-hook --remove"
  assert_success
  run grep "nixcage-hook-begin" "$TEST_TEMP_DIR/.zshrc"
  assert_failure
}

@test "install-hook: hook block contains begin delimiter" {
  touch "$TEST_TEMP_DIR/.zshrc"
  bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  run grep -q "nixcage-hook-begin" "$TEST_TEMP_DIR/.zshrc"
  assert_success
}

@test "install-hook: hook block contains end delimiter" {
  touch "$TEST_TEMP_DIR/.zshrc"
  bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/zsh bash '$NIXCAGE_BIN' install-hook"
  run grep -q "nixcage-hook-end" "$TEST_TEMP_DIR/.zshrc"
  assert_success
}

@test "install-hook: errors on unsupported shell" {
  run bash -c "HOME='$TEST_TEMP_DIR' SHELL=/bin/fish bash '$NIXCAGE_BIN' install-hook"
  assert_failure
  assert_output --partial "Unsupported shell"
}
