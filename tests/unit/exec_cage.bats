#!/usr/bin/env bats
# A command inside a running cage (ADR-012 point 6): the words that put it
# there, from the cage's leader and the leader's own environment, driven on
# a fixture proc tree with nothing entered.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/scope.sh
	source "$NIXCAGE_ROOT/modules/scope.sh"
	# shellcheck source=../../modules/exec-cage.sh
	source "$NIXCAGE_ROOT/modules/exec-cage.sh"
	export NIXCAGE_PROC="$TEST_TEMP_DIR/proc"
	mkdir -p "$NIXCAGE_PROC/4001"
	printf 'HOME=/home/builder\0PATH=/nix/store/abc-profile/bin\0TERM=xterm\0NIX_CONFIG=experimental-features = nix-command flakes\0' \
		>"$NIXCAGE_PROC/4001/environ"
}

teardown() {
	teardown_temp_dir
}

@test "the leader's own HOME and PATH are what the command gets, and nothing of the caller's" {
	run nixcage_exec_env 4001
	assert_success
	assert_line "HOME=/home/builder"
	assert_line "PATH=/nix/store/abc-profile/bin"
	refute_line --partial "TERM="
}

@test "the words enter every namespace of the leader, the user one included, in the workspace, as cage root" {
	run nixcage_exec_words 4001 "" -- git status
	assert_success
	assert_line --index 0 "nsenter"
	assert_line --index 1 "--target=4001"
	assert_line --index 2 "--mount"
	assert_line --index 3 "--uts"
	assert_line --index 4 "--ipc"
	assert_line --index 5 "--net"
	assert_line --index 6 "--pid"
	assert_line --index 7 "--user"
	assert_line --index 8 "--wd=/workspace"
	assert_line --index 9 -- "--"
	assert_line --index 10 "env"
	assert_line --index 11 "-i"
	assert_line --index 12 "HOME=/home/builder"
	assert_line --index 13 "PATH=/nix/store/abc-profile/bin"
	assert_line --index 14 "git"
	assert_line --index 15 "status"
}

@test "given a subject's offset, the command becomes that subject after entering" {
	run nixcage_exec_words 4001 7 -- id
	assert_success
	assert_line --index 10 "setpriv"
	assert_line --index 11 "--reuid=7"
	assert_line --index 12 "--regid=7"
	assert_line --index 13 "--clear-groups"
	assert_line --index 14 -- "--"
	assert_line --index 15 "env"
}

@test "no command means the cage's shell" {
	run nixcage_exec_words 4001 "" --
	assert_success
	assert_line --index 14 "bash"
}
