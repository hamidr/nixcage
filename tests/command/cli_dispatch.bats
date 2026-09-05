#!/usr/bin/env bats
# Top-level CLI dispatch: help, version, flake selection, unknown commands

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "no arguments shows help" {
	run_nixcage
	[ "$status" -eq 0 ]
	[[ "$output" == *Usage:* ]]
}

@test "every command the dispatcher accepts is in the help" {
	# Derived from the dispatcher rather than listed here, so adding a command
	# without documenting it fails instead of quietly shipping undiscoverable.
	run_nixcage help
	[ "$status" -eq 0 ]
	local commands
	commands="$(sed -n '/^  local command=/,/^  esac/p' "$NIXCAGE_BIN" |
		grep -oE '^  [a-z|-]+\)' | tr -d ' )' | tr '|' '\n' | grep -vE '^(--|-)')"
	[ -n "$commands" ]
	for cmd in $commands; do
		case "$cmd" in
		help | version) continue ;;
		esac
		[[ "$output" == *"$cmd"* ]] || {
			echo "the help does not mention: $cmd"
			return 1
		}
	done
}

@test "the help advertises nothing the dispatcher would reject" {
	run_nixcage help
	for word in install-hook init clone push; do
		[[ "$output" != *"$word"* ]]
	done
}

@test "version prints the version" {
	run_nixcage version
	[ "$status" -eq 0 ]
	[[ "$output" == "nixcage "* ]]
}

@test "unknown command fails with help" {
	run_nixcage frobnicate
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command"* ]]
}

@test "--flake without an argument fails" {
	run_nixcage --flake
	[ "$status" -ne 0 ]
	[[ "$output" == *"--flake requires"* ]]
}

@test "rebuild with a missing path flake fails with template guidance" {
	run_nixcage --flake "$TEST_TEMP_DIR/nonexistent" rebuild
	[ "$status" -ne 0 ]
	[[ "$output" == *"flake new"* ]]
}
