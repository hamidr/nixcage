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
	PROFILE="/nix/store/abc-profile/bin"
	printf 'HOME=/home/builder\0PATH=%s\0TERM=xterm\0NIX_CONFIG=experimental-features = nix-command flakes\0' "$PROFILE" \
		>"$NIXCAGE_PROC/4001/environ"
	# What the wrapper sets from its inputs: env and setpriv by store path.
	export NIXCAGE_EXEC_ENV="/nix/store/xyz-coreutils/bin/env" NIXCAGE_EXEC_SETPRIV="/nix/store/xyz-util-linux/bin/setpriv"
}

teardown() {
	teardown_temp_dir
}

@test "the leader's own HOME and PATH are what the command gets, and nothing of the caller's" {
	run nixcage_exec_env 4001
	assert_success
	assert_line "HOME=/home/builder"
	assert_line "PATH=$PROFILE"
	refute_line --partial "TERM="
}

# nsenter looks the command up with the caller's PATH inside the cage's
# filesystem, where /run/current-system and /usr/bin are nothing, and the
# cage's profile has no setpriv; both are named by store path, the same
# file inside as out.
@test "env and setpriv are named by store path, since the caller's PATH means nothing inside" {
	run nixcage_exec_words 4001 "" -- true
	assert_success
	assert_line "/nix/store/xyz-coreutils/bin/env"
	run nixcage_exec_words 4001 700004 -- true
	assert_success
	assert_line "/nix/store/xyz-util-linux/bin/setpriv"
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
	assert_line --index 8 "--wdns=/workspace"
	assert_line --index 9 -- "--"
	assert_line --index 10 "/nix/store/xyz-coreutils/bin/env"
	assert_line --index 11 "-i"
	assert_line --index 12 "HOME=/home/builder"
	assert_line --index 13 "PATH=$PROFILE"
	assert_line --index 14 "git"
	assert_line --index 15 "status"
}

@test "given a subject's offset, the command becomes that subject after entering" {
	run nixcage_exec_words 4001 7 -- id
	assert_success
	assert_line --index 10 "/nix/store/xyz-util-linux/bin/setpriv"
	assert_line --index 11 "--reuid=7"
	assert_line --index 12 "--regid=7"
	assert_line --index 13 "--clear-groups"
	assert_line --index 14 -- "--"
	assert_line --index 15 "/nix/store/xyz-coreutils/bin/env"
}

@test "no command means the cage's shell" {
	run nixcage_exec_words 4001 "" --
	assert_success
	assert_line --index 14 "bash"
}
