#!/usr/bin/env bats
# Unit tests for VM helper functions

setup() {
  load '../test_helper/common'
  setup_temp_dir
  source_nixcage
}

teardown() {
  teardown_temp_dir
}

@test "vm_is_running: returns false when pid file absent" {
  run vm_is_running "$TEST_TEMP_DIR"
  assert_failure
}

@test "vm_is_running: returns false for stale pid" {
  mkdir -p "$TEST_TEMP_DIR/$NIXCAGE_VM_DIR"
  # pid 99999 almost certainly does not exist
  echo "99999" >"$TEST_TEMP_DIR/$NIXCAGE_VM_DIR/vm.pid"
  run vm_is_running "$TEST_TEMP_DIR"
  assert_failure
}

@test "vm_is_running: returns true for a live process" {
  mkdir -p "$TEST_TEMP_DIR/$NIXCAGE_VM_DIR"
  sleep 60 &
  local live_pid=$!
  echo "$live_pid" >"$TEST_TEMP_DIR/$NIXCAGE_VM_DIR/vm.pid"
  run vm_is_running "$TEST_TEMP_DIR"
  kill "$live_pid" 2>/dev/null || true
  assert_success
}

@test "vm_pid_file: returns correct path" {
  result="$(vm_pid_file "/some/project")"
  assert_equal "$result" "/some/project/$NIXCAGE_VM_DIR/vm.pid"
}

@test "vm_read_config: reads SSH_PORT, SECRET_VARS, HYPERVISOR" {
  mkdir -p "$TEST_TEMP_DIR/$NIXCAGE_VM_DIR"
  cat >"$TEST_TEMP_DIR/$NIXCAGE_VM_DIR/config" <<'CFG'
SSH_PORT=12345
SECRET_VARS=ANTHROPIC_API_KEY,OPENAI_API_KEY
HYPERVISOR=cloud-hypervisor
SHARE_PROTO=virtiofs
NIX_SYSTEM=x86_64-linux
CFG
  vm_read_config "$TEST_TEMP_DIR"
  assert_equal "$VM_SSH_PORT" "12345"
  assert_equal "$VM_SECRET_VARS" "ANTHROPIC_API_KEY,OPENAI_API_KEY"
  assert_equal "$VM_HYPERVISOR" "cloud-hypervisor"
}

@test "vm_detect_ai_keys: returns keys that are set in env" {
  ANTHROPIC_API_KEY="test-key" \
  OPENAI_API_KEY="" \
  run bash -c '
    source "'"$NIXCAGE_BIN"'"
    vm_detect_ai_keys
  '
  assert_output --partial "ANTHROPIC_API_KEY"
}

@test "vm_detect_ai_keys: skips keys not set in env" {
  run bash -c '
    unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENCODE_API_KEY GITHUB_TOKEN
    source "'"$NIXCAGE_BIN"'"
    vm_detect_ai_keys
  '
  refute_output --partial "ANTHROPIC_API_KEY"
  refute_output --partial "OPENAI_API_KEY"
}

@test "vm_free_port: returns a number in range 1024-65535" {
  result="$(vm_free_port)"
  [[ "$result" -ge 1024 && "$result" -le 65535 ]]
}
