#!/usr/bin/env bats
# rm rejects malicious names and asks before doing anything expensive.

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "rm rejects a name with path traversal before any prompt" {
	run_nixcage rm "../../.."
	[ "$status" -ne 0 ]
	[[ "$output" == *"Invalid container name"* ]]
}

@test "rm rejects a name with shell metacharacters" {
	run_nixcage rm 'x;reboot'
	[ "$status" -ne 0 ]
	[[ "$output" == *"Invalid container name"* ]]
}

@test "rm answering no aborts before the VM is touched" {
	# No VM state exists at all: reaching the prompt and aborting must not
	# require or boot a VM.
	run bash -c "echo n | bash '$NIXCAGE_BIN' rm goodname"
	[ "$status" -eq 0 ]
	[[ "$output" == *Aborted* ]]
}

@test "status exits zero when the age key is not readable" {
	# Built-but-stopped state: the age-key line is simply absent.
	touch "$XDG_STATE_HOME/nixcage/result"
	run_nixcage status
	[ "$status" -eq 0 ]
}
