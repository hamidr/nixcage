#!/usr/bin/env bats
# Command tests for cmd_init

setup() {
  load '../test_helper/common'
  setup_temp_dir
}

teardown() {
  teardown_temp_dir
}

@test "init: creates nixcage.vm.nix in target dir" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -f "$TEST_TEMP_DIR/nixcage.vm.nix" ]]
}

@test "init: creates .nixcage-vm directory" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -d "$TEST_TEMP_DIR/.nixcage-vm" ]]
}

@test "init: creates .nixcage-vm/flake.nix" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -f "$TEST_TEMP_DIR/.nixcage-vm/flake.nix" ]]
}

@test "init: creates .nixcage-vm/config with required keys" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -f "$TEST_TEMP_DIR/.nixcage-vm/config" ]]
  run grep -q "SSH_PORT=" "$TEST_TEMP_DIR/.nixcage-vm/config"
  assert_success
  run grep -q "HYPERVISOR=" "$TEST_TEMP_DIR/.nixcage-vm/config"
  assert_success
  run grep -q "SHARE_PROTO=" "$TEST_TEMP_DIR/.nixcage-vm/config"
  assert_success
  run grep -q "NIX_SYSTEM=" "$TEST_TEMP_DIR/.nixcage-vm/config"
  assert_success
}

@test "init: creates ed25519 key pair" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -f "$TEST_TEMP_DIR/.nixcage-vm/id_ed25519" ]]
  [[ -f "$TEST_TEMP_DIR/.nixcage-vm/id_ed25519.pub" ]]
}

@test "init: creates .nixcage-vm/.gitignore" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  [[ -f "$TEST_TEMP_DIR/.nixcage-vm/.gitignore" ]]
}

@test "init: .gitignore ignores everything except itself" {
  run_nixcage init "$TEST_TEMP_DIR"
  run grep -q '^\*$' "$TEST_TEMP_DIR/.nixcage-vm/.gitignore"
  assert_success
  run grep -q '!.gitignore' "$TEST_TEMP_DIR/.nixcage-vm/.gitignore"
  assert_success
}

@test "init: flake.nix contains the public key" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  local pub_key
  pub_key="$(cat "$TEST_TEMP_DIR/.nixcage-vm/id_ed25519.pub")"
  run grep -qF "$pub_key" "$TEST_TEMP_DIR/.nixcage-vm/flake.nix"
  assert_success
}

@test "init: flake.nix contains the absolute project path" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  run grep -qF "$TEST_TEMP_DIR" "$TEST_TEMP_DIR/.nixcage-vm/flake.nix"
  assert_success
}

@test "init: flake.nix imports nixcage.nixosModules.base" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  run grep -q "nixcage.nixosModules.base" "$TEST_TEMP_DIR/.nixcage-vm/flake.nix"
  assert_success
}

@test "init: flake.nix imports microvm.nixosModules.microvm" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  run grep -q "microvm.nixosModules.microvm" "$TEST_TEMP_DIR/.nixcage-vm/flake.nix"
  assert_success
}

@test "init: fails if nixcage.vm.nix already exists" {
  touch "$TEST_TEMP_DIR/nixcage.vm.nix"
  run_nixcage init "$TEST_TEMP_DIR"
  assert_failure
  assert_output --partial "already exists"
}

@test "init: accepts a directory argument" {
  local subdir="$TEST_TEMP_DIR/myproject"
  mkdir -p "$subdir"
  run_nixcage init "$subdir"
  assert_success
  [[ -f "$subdir/nixcage.vm.nix" ]]
  [[ -d "$subdir/.nixcage-vm" ]]
}

@test "init: defaults to current directory" {
  local subdir="$TEST_TEMP_DIR/project"
  mkdir -p "$subdir"
  cd "$subdir"
  run_nixcage init
  assert_success
  [[ -f "$subdir/nixcage.vm.nix" ]]
}

@test "init: prints success message" {
  run_nixcage init "$TEST_TEMP_DIR"
  assert_success
  assert_output --partial "Initialized"
}
