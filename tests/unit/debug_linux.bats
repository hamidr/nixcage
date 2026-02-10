#!/usr/bin/env bats
# Unit tests for Linux --debug strace output parsing

setup() {
	load '../test_helper/common'
	# Source the nixcage script to get access to internal functions
	source "$NIXCAGE_BIN"
}

@test "_debug_cleanup_linux: parses ENOENT errors" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] openat(AT_FDCWD, "/nonexistent/file", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "ENOENT"
	assert_output --partial "openat"
	assert_output --partial "/nonexistent/file"
}

@test "_debug_cleanup_linux: parses EACCES errors" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] open("/root/secret", O_RDONLY) = -1 EACCES (Permission denied)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "EACCES"
	assert_output --partial "open"
	assert_output --partial "/root/secret"
}

@test "_debug_cleanup_linux: parses EPERM errors" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] mkdir("/forbidden", 0755) = -1 EPERM (Operation not permitted)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "EPERM"
	assert_output --partial "mkdir"
	assert_output --partial "/forbidden"
}

@test "_debug_cleanup_linux: deduplicates repeated errors" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 100] openat(AT_FDCWD, "/missing", O_RDONLY) = -1 ENOENT (No such file or directory)
[pid 101] openat(AT_FDCWD, "/missing", O_RDONLY) = -1 ENOENT (No such file or directory)
[pid 102] openat(AT_FDCWD, "/missing", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	# Should show count, not repeat 3 times
	assert_output --partial "3x"
	assert_output --partial "/missing"
}

@test "_debug_cleanup_linux: ignores /proc paths" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] openat(AT_FDCWD, "/proc/self/status", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: ignores /sys paths" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] openat(AT_FDCWD, "/sys/class/net", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: ignores nix store package lookups" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] openat(AT_FDCWD, "/nix/store/abc123-somepkg", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: keeps nix store subpath failures" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] openat(AT_FDCWD, "/nix/store/abc123-pkg/bin/missing", O_RDONLY) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "/nix/store/abc123-pkg/bin/missing"
}

@test "_debug_cleanup_linux: filters nix env hook lookups" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] newfstatat(AT_FDCWD, "/nix/store/abc-pkg/bin/envBuildBuildHook", 0x0, 0) = -1 ENOENT (No such file or directory)
[pid 12345] newfstatat(AT_FDCWD, "/nix/store/abc-pkg/bin/envHostTargetHook", 0x0, 0) = -1 ENOENT (No such file or directory)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: ignores non-access errors" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 12345] write(1, "hello", 5) = -1 EAGAIN (Resource temporarily unavailable)
[pid 12345] connect(3, ...) = -1 EINPROGRESS (Operation in progress)
STRACE

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: shows unique and total counts" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	cat >"$_NIXCAGE_DEBUG_LOG" <<'STRACE'
[pid 100] openat(AT_FDCWD, "/path/a", O_RDONLY) = -1 ENOENT (No such file or directory)
[pid 101] openat(AT_FDCWD, "/path/a", O_RDONLY) = -1 ENOENT (No such file or directory)
[pid 102] openat(AT_FDCWD, "/path/b", O_RDONLY) = -1 EACCES (Permission denied)
STRACE

	run _debug_cleanup_linux
	# 2 unique paths, 3 total failures
	assert_output --partial "2 unique"
	assert_output --partial "3 total"
}

@test "_debug_cleanup_linux: cleans up temp file" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	echo "test" >"$_NIXCAGE_DEBUG_LOG"
	local log_file="$_NIXCAGE_DEBUG_LOG"

	_debug_cleanup_linux

	[ ! -f "$log_file" ]
}

@test "_debug_cleanup_linux: handles empty log gracefully" {
	_NIXCAGE_DEBUG_LOG="$(mktemp)"
	touch "$_NIXCAGE_DEBUG_LOG"

	run _debug_cleanup_linux
	assert_output --partial "No sandbox access failures detected"
}

@test "_debug_cleanup_linux: handles missing log gracefully" {
	_NIXCAGE_DEBUG_LOG="/nonexistent/log/file"

	run _debug_cleanup_linux
	assert_success
}

# ─── Integration test: real strace run ───────────────────────────────────────

@test "integration: --debug with strace produces failure summary" {
	# Skip if not on Linux or strace not available
	[[ "$(uname -s)" == "Linux" ]] || skip "Linux only"
	command -v strace &>/dev/null || skip "strace not installed"
	command -v bwrap &>/dev/null || skip "bwrap not installed"

	setup_temp_dir

	# Initialize a cage
	run_nixcage init "$TEST_TEMP_DIR"

	# Run a command that will try to access a non-existent path
	cd "$TEST_TEMP_DIR"
	run timeout 120 bash "$NIXCAGE_BIN" run --debug -- cat /nonexistent/test/file

	# Should show the debug summary (either failures or "No sandbox access failures")
	assert_output --regexp "(Sandbox access failures|No sandbox access failures)"

	teardown_temp_dir
}
