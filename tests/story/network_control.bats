#!/usr/bin/env bats
# User Story: "As a developer, I disable network access for my sandboxed tools"
# Validates: Spec §4.2 [sandbox.network], §5.1, §5.2, §5.3

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "story: network is enabled by default" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_NET_ALLOW" "true"
}

@test "story: developer disables network via config" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.network]
allow = false
TOML

	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_NET_ALLOW" "false"
}

@test "story: network=false on linux removes --share-net and adds --unshare-net" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	# Build args for standard level (which has --share-net by default)
	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "standard" args

	# Simulate the network override logic from run_linux
	CAGE_NET_ALLOW="false"
	local filtered=()
	for arg in "${args[@]}"; do
		[[ "$arg" != "--share-net" ]] && filtered+=("$arg")
	done
	args=("${filtered[@]}" --unshare-net)

	local joined="${args[*]}"
	[[ "$joined" != *"--share-net"* ]]
	[[ "$joined" == *"--unshare-net"* ]]
}

@test "story: network=false on macOS strips allow network rules" {
	run_nixcage init "$TEST_TEMP_DIR"

	# Resolve the standard profile (which has network rules)
	local profile_src="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-standard.sb"
	local profile_resolved="$TEST_TEMP_DIR/.nixcage/profiles/sandbox-macos-resolved.sb"

	sed \
		-e "s|NIXCAGE_PROJECT_DIR|$TEST_TEMP_DIR|g" \
		-e "s|HOME_DIR|$HOME|g" \
		"$profile_src" >"$profile_resolved"

	# Verify network rules exist before stripping
	run grep -c 'allow network' "$profile_resolved"
	assert_success

	# Apply the network override (same logic as run_macos, portable sed -i)
	sed '/(allow network/d' "$profile_resolved" >"${profile_resolved}.tmp"
	mv "${profile_resolved}.tmp" "$profile_resolved"

	# Verify network rules are gone
	run grep 'allow network' "$profile_resolved"
	assert_failure
}

@test "story: strict level inherently has no network" {
	run_nixcage init "$TEST_TEMP_DIR"
	source "$TEST_TEMP_DIR/.nixcage/profiles/sandbox-linux.sh"

	local args=()
	build_bwrap_args "$TEST_TEMP_DIR" "strict" args

	local joined="${args[*]}"
	[[ "$joined" == *"--unshare-net"* ]]
	[[ "$joined" != *"--share-net"* ]]
}
