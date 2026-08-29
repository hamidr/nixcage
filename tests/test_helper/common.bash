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

# Isolate every test from the real user state and config. The OS is pinned
# to macos so the suite behaves identically on Linux CI/dev machines;
# linux_mode.bats overrides it.
setup_temp_dir() {
	TEST_TEMP_DIR="$(mktemp -d)"
	export TEST_TEMP_DIR
	export NIXCAGE_OS=macos
	export XDG_STATE_HOME="$TEST_TEMP_DIR/state"
	export NIXCAGE_FLAKE="$TEST_TEMP_DIR/config"
	mkdir -p "$XDG_STATE_HOME/nixcage" "$NIXCAGE_FLAKE"
}

teardown_temp_dir() {
	if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
		chmod -R u+w "$TEST_TEMP_DIR" 2>/dev/null || true
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

# Write the build-time cache the CLI reads at runtime.
write_cache() {
	local port="${1:-22022}"
	local roots="${2:-$TEST_TEMP_DIR/src}"
	cat >"$XDG_STATE_HOME/nixcage/cache" <<EOF
SSH_PORT=$port
WORKSPACE_ROOTS=$roots
EOF
}
