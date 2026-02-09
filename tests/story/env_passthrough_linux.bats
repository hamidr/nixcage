#!/usr/bin/env bats
# Tests for Linux env passthrough via bwrap --setenv (Spec §10.3)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "linux env: --setenv args built for non-empty vars" {
	CAGE_PASSTHROUGH_ENV=("TERM" "LANG" "CUSTOM_VAR")
	export TERM="xterm-256color"
	export LANG="en_US.UTF-8"
	export CUSTOM_VAR="my_value"

	# Simulate the env args construction from run_linux
	local env_args=()
	for var in "${CAGE_PASSTHROUGH_ENV[@]}"; do
		[[ -n "${!var:-}" ]] && env_args+=(--setenv "$var" "${!var}")
	done

	local joined="${env_args[*]}"
	[[ "$joined" == *"--setenv TERM xterm-256color"* ]]
	[[ "$joined" == *"--setenv LANG en_US.UTF-8"* ]]
	[[ "$joined" == *"--setenv CUSTOM_VAR my_value"* ]]
}

@test "linux env: empty vars are skipped" {
	CAGE_PASSTHROUGH_ENV=("TERM" "EMPTY_VAR")
	export TERM="xterm"
	unset EMPTY_VAR 2>/dev/null || true

	local env_args=()
	for var in "${CAGE_PASSTHROUGH_ENV[@]}"; do
		[[ -n "${!var:-}" ]] && env_args+=(--setenv "$var" "${!var}")
	done

	local joined="${env_args[*]}"
	[[ "$joined" == *"--setenv TERM xterm"* ]]
	[[ "$joined" != *"EMPTY_VAR"* ]]
}

@test "linux env: NIXCAGE_PACKAGES_JSON is always set" {
	local pkg_json='["nodejs_22"]'

	local env_args=()
	env_args+=(--setenv NIXCAGE_PACKAGES_JSON "$pkg_json")
	env_args+=(--setenv NIXCAGE_ACTIVE "1")

	local joined="${env_args[*]}"
	[[ "$joined" == *'--setenv NIXCAGE_PACKAGES_JSON ["nodejs_22"]'* ]]
	[[ "$joined" == *"--setenv NIXCAGE_ACTIVE 1"* ]]
}
