#!/usr/bin/env bats
# A guest's proposed enter or exec line, validated before the host runs it
# (ADR-027): the grammar plan owns, driven on words it composes without a
# machine, an enter or exec, or a caller in the loop.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/plan.sh
	source "$NIXCAGE_ROOT/modules/plan.sh"
}

teardown() {
	teardown_temp_dir
}

plan_words() {
	mapfile -d "" -t words < <(nixcage_plan_words "$@")
}

@test "an enter plan is prefixed with the machine plan itself was given" {
	plan_words myfactory "" -- enter --uid 5 mycage /workspace
	assert_equal "${words[0]}" "enter"
	assert_equal "${words[1]}" "--machine"
	assert_equal "${words[2]}" "myfactory"
	assert_equal "${words[3]}" "--uid"
	assert_equal "${words[4]}" "5"
	assert_equal "${words[5]}" "mycage"
	assert_equal "${words[6]}" "/workspace"
	assert_equal "${#words[@]}" 7
}

@test "an exec plan is prefixed the same way" {
	plan_words myfactory "" -- exec mycage -- git status
	assert_equal "${words[0]}" "exec"
	assert_equal "${words[1]}" "--machine"
	assert_equal "${words[2]}" "myfactory"
	assert_equal "${words[3]}" "mycage"
	assert_equal "${words[4]}" "--"
	assert_equal "${words[5]}" "git"
	assert_equal "${words[6]}" "status"
}

@test "a verb the plan's caller wrote is taken off as well as plan's own separator" {
	plan_words myfactory "" -- -- enter mycage /workspace
	assert_equal "${words[0]}" "enter"
}

@test "a verb outside enter and exec is refused" {
	run nixcage_plan_words myfactory "" -- machine down otherfactory
	assert_failure
	assert_output --partial "a plan may only run enter or exec"
	assert_output --partial "machine"
}

@test "an empty plan is refused" {
	run nixcage_plan_words myfactory "" --
	assert_failure
	assert_output --partial "a plan may only run enter or exec"
}

@test "a plan naming --auth-sock anywhere in its own words is refused" {
	run nixcage_plan_words myfactory "" -- enter --auth-sock /tmp/evil.sock mycage /workspace
	assert_failure
	assert_output --partial "--auth-sock"
}

# Which machine runs is never the guest's to say (ADR-027): a plan that
# tries to name its own --machine is refused, not silently overridden and
# not let through to fall through as a positional in enter's own parser.
@test "a plan naming --machine anywhere in its own words is refused" {
	run nixcage_plan_words myfactory "" -- enter --machine otherfactory mycage /workspace
	assert_failure
	assert_output --partial "--machine"
}

@test "the caller's auth-sock, when there is one, lands right after --machine and before the guest's words" {
	plan_words myfactory /run/agent.sock -- enter --uid 5 mycage /workspace
	assert_equal "${words[0]}" "enter"
	assert_equal "${words[1]}" "--machine"
	assert_equal "${words[2]}" "myfactory"
	assert_equal "${words[3]}" "--auth-sock"
	assert_equal "${words[4]}" "/run/agent.sock"
	assert_equal "${words[5]}" "--uid"
	assert_equal "${words[6]}" "5"
}

@test "no auth-sock given means none is added" {
	plan_words myfactory "" -- enter mycage /workspace
	assert_equal "${words[3]}" "mycage"
}

# The words are NUL-terminated records: a guest word with an embedded
# newline (a script handed to exec) survives as one word, the same
# invariant nixcage_exec_words holds.
@test "a guest word with an embedded newline survives as one word" {
	plan_words myfactory "" -- exec mycage -- bash -c "$(printf 'echo one\necho two')"
	assert_equal "${words[3]}" "mycage"
	assert_equal "${words[4]}" "--"
	assert_equal "${words[5]}" "bash"
	assert_equal "${words[6]}" "-c"
	assert_equal "${words[7]}" "echo one
echo two"
}
