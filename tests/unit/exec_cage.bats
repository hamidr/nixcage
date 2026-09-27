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

# The words are NUL-terminated records, not newline-terminated: a command
# argument or an environment value may itself contain a newline, and a
# newline-per-word wire format would split it into spurious extra words.
# mapfile -d '' is the same pattern the microvm exec path already uses.
exec_words() {
	mapfile -d "" -t words < <(nixcage_exec_words "$@")
}

# A session's environment is the cage's: where pi reads its directory,
# which bus to speak on, who the role is. A hand that got HOME and PATH
# alone read an empty PI_CODING_AGENT_DIR and answered for nobody.
@test "the leader's whole environment is what the command gets, and nothing of the caller's" {
	local -a env_words=()
	mapfile -d "" -t env_words < <(nixcage_exec_env 4001)
	assert_equal "${#env_words[@]}" 4
	printf '%s\n' "${env_words[@]}" | grep -qx "HOME=/home/builder"
	printf '%s\n' "${env_words[@]}" | grep -qx "PATH=$PROFILE"
	printf '%s\n' "${env_words[@]}" | grep -qx "NIX_CONFIG=experimental-features = nix-command flakes"
	printf '%s\n' "${env_words[@]}" | grep -qx "TERM=xterm"
}

# An environment value with an embedded newline is one record, not two: the
# NUL delimiter is the only thing read -d '' looks for.
@test "an environment value with an embedded newline survives as one record" {
	printf 'HOME=/home/builder\0MULTILINE=first\nsecond\0' >"$NIXCAGE_PROC/4001/environ"
	local -a env_words=()
	mapfile -d "" -t env_words < <(nixcage_exec_env 4001)
	assert_equal "${#env_words[@]}" 2
	assert_equal "${env_words[1]}" "MULTILINE=first
second"
}

# nsenter looks the command up with the caller's PATH inside the cage's
# filesystem, where /run/current-system and /usr/bin are nothing, and the
# cage's profile has no setpriv; both are named by store path, the same
# file inside as out.
@test "env and setpriv are named by store path, since the caller's PATH means nothing inside" {
	exec_words 4001 "" -- true
	printf '%s\n' "${words[@]}" | grep -qx "/nix/store/xyz-coreutils/bin/env"
	exec_words 4001 700004 -- true
	printf '%s\n' "${words[@]}" | grep -qx "/nix/store/xyz-util-linux/bin/setpriv"
}

@test "the words enter every namespace of the leader, the user one included, in the workspace, as cage root" {
	exec_words 4001 "" -- git status
	assert_equal "${words[0]}" "nsenter"
	assert_equal "${words[1]}" "--target=4001"
	assert_equal "${words[2]}" "--mount"
	assert_equal "${words[3]}" "--uts"
	assert_equal "${words[4]}" "--ipc"
	assert_equal "${words[5]}" "--net"
	assert_equal "${words[6]}" "--pid"
	assert_equal "${words[7]}" "--user"
	assert_equal "${words[8]}" "--wdns=/workspace"
	assert_equal "${words[9]}" "--"
	assert_equal "${words[10]}" "/nix/store/xyz-coreutils/bin/env"
	assert_equal "${words[11]}" "-i"
	assert_equal "${words[16]}" "git"
	assert_equal "${words[17]}" "status"
}

@test "given a subject's offset, the command becomes that subject after entering" {
	exec_words 4001 7 -- id
	assert_equal "${words[10]}" "/nix/store/xyz-util-linux/bin/setpriv"
	assert_equal "${words[11]}" "--reuid=7"
	assert_equal "${words[12]}" "--regid=7"
	assert_equal "${words[13]}" "--clear-groups"
	assert_equal "${words[14]}" "--"
	assert_equal "${words[15]}" "/nix/store/xyz-coreutils/bin/env"
}

# The verb's caller writes "exec <name> -- cmd", and the verb hands the
# rest on with a separator of its own; the second reached env as its
# command: "env: '--': No such file or directory".
@test "a separator the caller wrote is taken off as well as the verb's own" {
	exec_words 4001 "" -- -- git status
	assert_equal "${words[16]}" "git"
	assert_equal "${words[17]}" "status"
}

@test "no command means the cage's shell" {
	exec_words 4001 "" --
	assert_equal "${words[16]}" "bash"
}

# The bug this guards: a script argument with an embedded newline used to
# be split into several spurious words by a newline-per-word wire format,
# so only the argument's first line survived as the command.
@test "a command argument with an embedded newline arrives as one word" {
	exec_words 4001 "" -- bash -c "$(printf 'echo one\necho two')"
	assert_equal "${#words[@]}" 19
	assert_equal "${words[16]}" "bash"
	assert_equal "${words[17]}" "-c"
	assert_equal "${words[18]}" "echo one
echo two"
}
