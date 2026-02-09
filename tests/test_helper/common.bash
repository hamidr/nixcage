#!/usr/bin/env bash
# Shared test helper for nixcage bats tests

NIXCAGE_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
NIXCAGE_BIN="${NIXCAGE_ROOT}/nixcage"

# Load bats libraries via BATS_LIB_PATH (set by nix devShell)
if [[ -n "${BATS_LIB_PATH:-}" ]]; then
	IFS=':' read -ra _lib_dirs <<<"$BATS_LIB_PATH"
	for _dir in "${_lib_dirs[@]}"; do
		[[ -f "$_dir/bats-support/load.bash" ]] && load "$_dir/bats-support/load.bash"
	done
	for _dir in "${_lib_dirs[@]}"; do
		[[ -f "$_dir/bats-assert/load.bash" ]] && load "$_dir/bats-assert/load.bash"
	done
	unset _lib_dirs _dir
fi

# Create a fresh temp directory for each test
setup_temp_dir() {
	TEST_TEMP_DIR="$(mktemp -d)"
	export TEST_TEMP_DIR
}

# Clean up temp directory after each test
teardown_temp_dir() {
	if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
		rm -rf "$TEST_TEMP_DIR"
	fi
}

# Source nixcage functions without executing main
source_nixcage() {
	source "$NIXCAGE_BIN"
}

# Run nixcage as a command (not sourced)
run_nixcage() {
	run bash "$NIXCAGE_BIN" "$@"
}

# Create a minimal nixcage.toml for testing
create_test_config() {
	local dir="${1:-.}"
	cat >"$dir/nixcage.toml" <<'TOML'
[sandbox]
level = "standard"

[sandbox.filesystem]
ro_bind = []
rw_bind = []
blacklist = []

[sandbox.network]
allow = true

[sandbox.resources]
cpus = 0
memory = ""

[nix]
packages = ["nodejs_22"]
pure = true
store_mode = "readonly"

[cage]
command = ""
passthrough_env = ["TERM", "LANG", "ANTHROPIC_API_KEY"]
TOML
}
