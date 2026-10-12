#!/usr/bin/env bats
# Where the CLI's own lines go: progress on stderr so a command's stdout is
# its output alone, and colour only for a terminal that wants it.

bats_require_minimum_version 1.5.0

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

ESC=$'\033'

# Call one of the CLI's log functions with its fds as the caller sets them.
log_line() {
	bash -c 'source "$1"; shift; "$@"' _ "$NIXCAGE_BIN" "$@"
}

# Run a shell line with a pseudo-terminal on every fd. util-linux and BSD
# spell script(1) differently.
run_on_tty() {
	if script --version >/dev/null 2>&1; then
		run script -qec "$1" /dev/null
	else
		run script -q /dev/null bash -c "$1"
	fi
}

@test "a progress line goes to stderr, leaving stdout to the command's output" {
	for level in log_info log_ok log_warn log_err; do
		run --separate-stderr log_line "$level" hello
		[ "$status" -eq 0 ]
		[ -z "$output" ] || {
			echo "$level wrote to stdout: $output"
			return 1
		}
		[[ "$stderr" == *"[nixcage] hello"* ]]
	done
}

@test "a log line written to a pipe carries no escape codes" {
	run --separate-stderr log_line log_warn hello
	[[ "$stderr" != *"$ESC"* ]]
	[ "$stderr" = "[nixcage] hello" ]
}

@test "a log line on a terminal is coloured" {
	run_on_tty "$(printf '%q ' bash -c 'source "$1"; log_warn hello' _ "$NIXCAGE_BIN")"
	[[ "$output" == *"$ESC["* ]]
}

@test "NO_COLOR keeps a terminal's log lines plain" {
	run_on_tty "NO_COLOR=1 $(printf '%q ' bash -c 'source "$1"; log_warn hello' _ "$NIXCAGE_BIN")"
	[[ "$output" == *"[nixcage] hello"* ]]
	[[ "$output" != *"$ESC"* ]]
}

@test "help written to a pipe carries no escape codes" {
	run --separate-stderr bash "$NIXCAGE_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *Usage:* ]]
	[[ "$output" != *"$ESC"* ]]
}

@test "help on a terminal is still bold" {
	run_on_tty "$(printf '%q ' bash "$NIXCAGE_BIN" help)"
	[[ "$output" == *"$ESC[1m"* ]]
}
