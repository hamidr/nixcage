#!/usr/bin/env bats
# Tests for macOS bash -c command string construction (Spec §10.3)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "macos cmd: env exports use single-quote escaping" {
	CAGE_PASSTHROUGH_ENV=("TERM" "MY_KEY")
	export TERM="xterm"
	export MY_KEY="value with spaces"

	local env_exports=""
	for var in "${CAGE_PASSTHROUGH_ENV[@]}"; do
		[[ -n "${!var:-}" ]] && env_exports+="export ${var}='$(escape_sq "${!var}")'; "
	done

	[[ "$env_exports" == *"export TERM='xterm'"* ]]
	[[ "$env_exports" == *"export MY_KEY='value with spaces'"* ]]
}

@test "macos cmd: single quotes in env values are escaped" {
	export DANGER="it's dangerous"

	local escaped_export
	escaped_export="export DANGER='$(escape_sq "$DANGER")'; "

	# The export string should be eval-safe
	local recovered
	recovered="$(eval "${escaped_export} printf '%s' \"\$DANGER\"")"
	assert_equal "$recovered" "it's dangerous"
}

@test "macos cmd: project dir is single-quoted in cd" {
	local project_dir="/tmp/my project"
	local cd_cmd
	cd_cmd="cd '$(escape_sq "$project_dir")'"

	[[ "$cd_cmd" == "cd '/tmp/my project'" ]]
}

@test "macos cmd: nix-shell path is single-quoted" {
	local shell_nix="/tmp/test/.nixcage/shell.nix"
	local nix_cmd
	nix_cmd="nix-shell '$(escape_sq "$shell_nix")'"

	[[ "$nix_cmd" == "nix-shell '/tmp/test/.nixcage/shell.nix'" ]]
}

@test "macos cmd: --run argument is single-quoted and escaped" {
	local user_cmd="echo 'hello world'"
	local nix_cmd
	nix_cmd="nix-shell '/tmp/shell.nix' --run '$(escape_sq "$user_cmd")'"

	# Should be safely quoted
	[[ "$nix_cmd" == *"--run '"* ]]
}

@test "macos cmd: NIXCAGE_PACKAGES_JSON is always included" {
	local pkg_json='["nodejs_22"]'

	local env_exports=""
	env_exports+="export NIXCAGE_PACKAGES_JSON='$(escape_sq "$pkg_json")'; "
	env_exports+="export NIXCAGE_ACTIVE=1; "

	[[ "$env_exports" == *"NIXCAGE_PACKAGES_JSON="* ]]
	[[ "$env_exports" == *"NIXCAGE_ACTIVE=1"* ]]
}
