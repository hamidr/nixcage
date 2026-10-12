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

# A question about a verb is answered before anything about this machine is,
# so a person who has built nothing yet can still read what enter takes.

@test "every verb answers -h and --help with the help, before reading any state" {
	for verb in enter exec list rm status down rebuild; do
		for ask in -h --help; do
			run_nixcage "$verb" "$ask"
			[ "$status" -eq 0 ] || {
				echo "$verb $ask exited $status: $output"
				return 1
			}
			[[ "$output" == *Usage:* ]]
			[[ "$output" != *"not been built"* ]]
		done
	done
}

@test "an unknown enter flag is named before the VM's state is" {
	run_nixcage enter --bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown flag: --bogus"* ]]
	[[ "$output" != *"not been built"* ]]
}

# --flake chooses the configuration every verb reads, so it is read once,
# first; after the verb it is refused by name rather than ignored or, for
# exec, taken for the command.

@test "--flake after the verb is refused, saying where it goes" {
	for args in "status --flake x" "list --flake x" "rm --flake x" \
		"enter --flake x" "enter --no-agent --flake=x" "exec --flake x -- true" \
		"exec --tty --flake x -- true"; do
		# shellcheck disable=SC2086
		run_nixcage $args
		[ "$status" -ne 0 ] || {
			echo "accepted: $args"
			return 1
		}
		[[ "$output" == *"nixcage --flake <ref> <command>"* ]] || {
			echo "$args: $output"
			return 1
		}
	done
}
