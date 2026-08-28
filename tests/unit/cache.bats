#!/usr/bin/env bats
# vm_read_cache loads the build-time cache into VM_* globals

load ../test_helper/common

setup() {
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "reads port and roots" {
	write_cache 12345 "/a:/b"
	vm_read_cache
	[ "$VM_SSH_PORT" = "12345" ]
	[ "$VM_WORKSPACE_ROOTS" = "/a:/b" ]
}

@test "unknown keys are ignored" {
	write_cache 12345 "/a"
	echo "BOGUS=1" >>"$XDG_STATE_HOME/nixcage/cache"
	vm_read_cache
	[ "$VM_SSH_PORT" = "12345" ]
}

@test "missing cache exits with rebuild guidance" {
	run vm_read_cache
	[ "$status" -ne 0 ]
	[[ "$output" == *rebuild* ]]
}
