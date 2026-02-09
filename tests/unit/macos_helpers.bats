#!/usr/bin/env bats
# Unit tests for macOS helper functions extracted from run_macos()

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

# ─── build_macos_store_rules ────────────────────────────────────────────────

@test "build_macos_store_rules: shared returns empty" {
	local result
	result="$(build_macos_store_rules "shared")"
	assert_equal "$result" ""
}

@test "build_macos_store_rules: readonly returns deny rule" {
	local result
	result="$(build_macos_store_rules "readonly")"
	assert_equal "$result" '(deny file-write* (subpath "/nix"))'
}

@test "build_macos_store_rules: copy returns deny rule" {
	local result
	result="$(build_macos_store_rules "copy")"
	assert_equal "$result" '(deny file-write* (subpath "/nix"))'
}

@test "build_macos_store_rules: isolated returns deny rule" {
	local result
	result="$(build_macos_store_rules "isolated")"
	assert_equal "$result" '(deny file-write* (subpath "/nix"))'
}

@test "build_macos_store_rules: invalid mode returns error" {
	run build_macos_store_rules "bogus"
	assert_failure
}

# ─── build_macos_env_exports ────────────────────────────────────────────────

@test "build_macos_env_exports: includes set env vars" {
	export TERM="xterm"
	export LANG="en_US.UTF-8"
	local passthrough=("TERM" "LANG")

	local result
	result="$(build_macos_env_exports '["nodejs_22"]' passthrough)"

	[[ "$result" == *"export TERM='xterm'"* ]]
	[[ "$result" == *"export LANG='en_US.UTF-8'"* ]]
}

@test "build_macos_env_exports: skips unset vars" {
	unset NONEXISTENT_VAR 2>/dev/null || true
	local passthrough=("NONEXISTENT_VAR")

	local result
	result="$(build_macos_env_exports '[]' passthrough)"

	[[ "$result" != *"NONEXISTENT_VAR"* ]]
}

@test "build_macos_env_exports: skips empty vars" {
	export EMPTY_VAR=""
	local passthrough=("EMPTY_VAR")

	local result
	result="$(build_macos_env_exports '[]' passthrough)"

	[[ "$result" != *"EMPTY_VAR"* ]]
}

@test "build_macos_env_exports: escapes single quotes in values" {
	export DANGER="it's dangerous"
	local passthrough=("DANGER")

	local result
	result="$(build_macos_env_exports '[]' passthrough)"

	# The value should be safely escaped
	[[ "$result" == *"DANGER="* ]]
	# Verify round-trip safety
	local recovered
	recovered="$(eval "${result} printf '%s' \"\$DANGER\"")"
	assert_equal "$recovered" "it's dangerous"
}

@test "build_macos_env_exports: always includes NIXCAGE_PACKAGES_JSON" {
	local passthrough=()

	local result
	result="$(build_macos_env_exports '["git"]' passthrough)"

	[[ "$result" == *"NIXCAGE_PACKAGES_JSON="* ]]
}

@test "build_macos_env_exports: always includes NIXCAGE_ACTIVE=1" {
	local passthrough=()

	local result
	result="$(build_macos_env_exports '[]' passthrough)"

	[[ "$result" == *"NIXCAGE_ACTIVE=1"* ]]
}

# ─── build_macos_command ────────────────────────────────────────────────────

@test "build_macos_command: basic assembly without command" {
	local result
	result="$(build_macos_command "export A=1; " "/tmp/proj" "/tmp/proj/.nixcage/shell.nix" "false")"

	[[ "$result" == *"export A=1; "* ]]
	[[ "$result" == *"cd '/tmp/proj'"* ]]
	[[ "$result" == *"nix-shell '/tmp/proj/.nixcage/shell.nix'"* ]]
	[[ "$result" != *"--run"* ]]
}

@test "build_macos_command: adds --pure flag" {
	local result
	result="$(build_macos_command "" "/tmp/proj" "/tmp/shell.nix" "true")"

	[[ "$result" == *"--pure"* ]]
}

@test "build_macos_command: no --pure when false" {
	local result
	result="$(build_macos_command "" "/tmp/proj" "/tmp/shell.nix" "false")"

	[[ "$result" != *"--pure"* ]]
}

@test "build_macos_command: --run with user command" {
	local result
	result="$(build_macos_command "" "/tmp/proj" "/tmp/shell.nix" "false" "echo hello")"

	[[ "$result" == *"--run 'echo hello'"* ]]
}

@test "build_macos_command: --run escapes single quotes in command" {
	local result
	result="$(build_macos_command "" "/tmp/proj" "/tmp/shell.nix" "false" "echo 'hi'")"

	[[ "$result" == *"--run '"* ]]
	# Should contain escaped quote
	[[ "$result" == *"'\\''hi'\\'"* ]]
}

@test "build_macos_command: handles spaces in project dir" {
	local result
	result="$(build_macos_command "" "/tmp/my project" "/tmp/my project/shell.nix" "false")"

	[[ "$result" == *"cd '/tmp/my project'"* ]]
	[[ "$result" == *"nix-shell '/tmp/my project/shell.nix'"* ]]
}

# ─── strip_macos_network_rules ──────────────────────────────────────────────

@test "strip_macos_network_rules: removes network lines" {
	cat >"$TEST_TEMP_DIR/test.sb" <<'SB'
(version 1)
(deny default)
(allow process-exec)
(allow network-outbound)
(allow network-inbound)
(allow file-read* (subpath "/nix"))
SB

	strip_macos_network_rules "$TEST_TEMP_DIR/test.sb"

	run grep 'network' "$TEST_TEMP_DIR/test.sb"
	assert_failure

	# Other rules preserved
	run grep 'process-exec' "$TEST_TEMP_DIR/test.sb"
	assert_success
	run grep 'file-read' "$TEST_TEMP_DIR/test.sb"
	assert_success
}

@test "strip_macos_network_rules: preserves non-network rules" {
	cat >"$TEST_TEMP_DIR/test.sb" <<'SB'
(version 1)
(deny default)
(allow process-exec)
(allow process-fork)
(allow network-outbound)
(allow file-read* (subpath "/nix"))
SB

	strip_macos_network_rules "$TEST_TEMP_DIR/test.sb"

	local line_count
	line_count="$(wc -l <"$TEST_TEMP_DIR/test.sb" | tr -d ' ')"
	assert_equal "$line_count" "5"
}

@test "strip_macos_network_rules: no-op when no network rules" {
	cat >"$TEST_TEMP_DIR/test.sb" <<'SB'
(version 1)
(deny default)
(allow process-exec)
SB

	local before
	before="$(cat "$TEST_TEMP_DIR/test.sb")"

	strip_macos_network_rules "$TEST_TEMP_DIR/test.sb"

	local after
	after="$(cat "$TEST_TEMP_DIR/test.sb")"
	assert_equal "$after" "$before"
}
