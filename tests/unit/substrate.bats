#!/usr/bin/env bats
# Which substrate a cage runs on (ADR-019): decided when the cage is defined,
# then fixed. A table over the four inputs, and the refusals that name the
# winner and its source.

load ../test_helper/common

setup() {
	# shellcheck source=../../modules/substrate.sh
	source "$NIXCAGE_ROOT/modules/substrate.sh"
}

# nixcage_substrate_resolve <name> <declared> <recorded> <flag> <default>

@test "nothing given is nspawn" {
	run nixcage_substrate_resolve myproj "" "" "" ""
	[ "$status" -eq 0 ]
	[ "$output" = nspawn ]
}

@test "the host's default answers when nothing closer does" {
	run nixcage_substrate_resolve myproj "" "" "" microvm
	[ "$output" = microvm ]
}

@test "the flag beats the default" {
	run nixcage_substrate_resolve myproj "" "" nspawn microvm
	[ "$output" = nspawn ]
}

@test "the record of the first enter beats the flag's absence" {
	run nixcage_substrate_resolve myproj "" microvm "" nspawn
	[ "$output" = microvm ]
}

@test "a flag that agrees with the record is fine" {
	run nixcage_substrate_resolve myproj "" microvm microvm ""
	[ "$status" -eq 0 ]
	[ "$output" = microvm ]
}

@test "a flag against the record is refused naming the record" {
	run nixcage_substrate_resolve myproj "" microvm nspawn ""
	[ "$status" -eq 1 ]
	[ "$output" = "nixcage: myproj runs on microvm by its record; --substrate nspawn refused" ]
}

@test "the declaration beats the record" {
	# A record written before the host declared the cage: the declaration
	# is what the admin said, the record is what once happened.
	run nixcage_substrate_resolve myproj nspawn microvm "" ""
	[ "$output" = nspawn ]
}

@test "a flag against the declaration is refused naming the declaration" {
	run nixcage_substrate_resolve myproj microvm "" nspawn ""
	[ "$status" -eq 1 ]
	[ "$output" = "nixcage: myproj runs on microvm by the host's declaration; --substrate nspawn refused" ]
}

@test "a word that is not a substrate is refused wherever it comes from" {
	run nixcage_substrate_resolve myproj "" "" firecracker ""
	[ "$status" -eq 1 ]
	[ "$output" = "nixcage: not a substrate: firecracker" ]
	run nixcage_substrate_resolve myproj "" "" "" docker
	[ "$status" -eq 1 ]
	[ "$output" = "nixcage: not a substrate: docker" ]
	run nixcage_substrate_resolve myproj "" lxc "" ""
	[ "$status" -eq 1 ]
	[ "$output" = "nixcage: not a substrate: lxc" ]
}

@test "the word check stands on its own" {
	nixcage_substrate_word_ok nspawn
	nixcage_substrate_word_ok microvm
	! nixcage_substrate_word_ok ""
	! nixcage_substrate_word_ok Microvm
}

# nixcage_substrate_declared <project> <declarations>: the word declared for
# a project path, from the lines the host rendered.

@test "a project's declared substrate is read by its exact path" {
	local decl=$'/srv/trusted nspawn\n/srv/untrusted microvm'
	run nixcage_substrate_declared /srv/untrusted "$decl"
	assert_output microvm
	run nixcage_substrate_declared /srv/trusted "$decl"
	assert_output nspawn
	run nixcage_substrate_declared /srv/untrusted-2 "$decl"
	assert_success
	assert_output ""
	run nixcage_substrate_declared /srv/x ""
	assert_output ""
}
