#!/usr/bin/env bats
# The interface nixcage exports, asserted against the guest script's source.
#
# The behaviour lives in enter_args.bats, bind.bats, storage.bats and
# principal_uid.bats, which drive it. What is left over is the shape: which
# verbs the guest script dispatches, and whether a flag the parser accepts is
# one a caller could ever have found. Both are the way an exported interface
# usually breaks -- something is renamed for a reason that looked local, and
# the dependant finds out at run time -- and neither is visible from a test
# that only calls functions.

load ../test_helper/common

CONTAINER_NIX() { echo "$NIXCAGE_ROOT/modules/container.nix"; }
ENTER_ARGS() { echo "$NIXCAGE_ROOT/modules/enter-args.sh"; }

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "the exported verbs are dispatched" {
	# enter builds a session, uid names a principal's number, storage gives a
	# path to that number. Everything built on nixcage is built on these.
	for verb in enter uid storage; do
		run grep -qE "^      $verb\)" "$(CONTAINER_NIX)"
		assert_success
	done
}

@test "list and rm stay, because the CLI still calls them" {
	for verb in list rm; do
		run grep -qE "^      $verb\)" "$(CONTAINER_NIX)"
		assert_success
	done
}

@test "enter accepts every flag a caller parameterises a session with" {
	for flag in --uid --user --home --shell --bind --bind-ro --setenv --no-agent --auth-sock; do
		run grep -qE "^$(printf '\t\t')$flag\)" "$(ENTER_ARGS)"
		assert_success
	done
}

@test "every flag enter accepts is in its usage line" {
	# The usage line is the only description of this interface a caller sees
	# at run time, so a flag missing from it is a flag nobody finds.
	local usage
	usage="$(grep -o 'usage: nixcage-container enter[^"]*' "$(CONTAINER_NIX)" | head -1)"
	[ -n "$usage" ]
	local flags
	flags="$(grep -oE "^$(printf '\t\t')--[a-z-]+\)" "$(ENTER_ARGS)" |
		tr -d "$(printf '\t')" | tr -d ')')"
	[ -n "$flags" ]
	for flag in $flags; do
		[[ "$usage" == *"$flag"* ]] || {
			echo "the usage line does not mention: $flag"
			return 1
		}
	done
}

@test "the parser is a file the suite can drive, not a loop in a Nix string" {
	# An interface nothing can drive breaks at a dependant's run time rather
	# than at ours.
	[ -f "$(ENTER_ARGS)" ]
	run grep -q 'nixcage_enter_parse "$@"' "$(CONTAINER_NIX)"
	assert_success
}

@test "asked-for binds and environment go through the check rather than around it" {
	# A --bind that reached nspawn without nixcage_bind_arg would be the whole
	# widened surface with none of the refusals on it.
	run grep -c 'nixcage_bind_arg' "$(ENTER_ARGS)"
	assert_output "2"
	run grep -c 'nixcage_setenv_arg' "$(ENTER_ARGS)"
	assert_output "1"
}

@test "the storage verb never lets a caller name a dataset" {
	# Which of a dataset and a directory a path becomes is nixcage's decision.
	run grep -qE 'storage ensure <path> <uid> \[quota\]' "$(CONTAINER_NIX)"
	assert_success
	run grep -c 'zfs ' "$(CONTAINER_NIX)"
	assert_output "0"
}

@test "the uid store carries its allocations across the rename" {
	# Renaming it without moving it would reallocate every number, and a
	# reissued uid hands something new the files of something dead.
	run grep -q 'mv "$STATE_DIR/role-uids" "$store"' "$(CONTAINER_NIX)"
	assert_success
}
