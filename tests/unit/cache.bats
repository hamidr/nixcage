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


# A store path name may hold an =, and a reader that splits on every one of
# them keeps only what precedes the second.

@test "a store path with an equals sign in its name survives the cache" {
	mkdir -p "$TEST_TEMP_DIR/store/g-nixos=system"
	MICROVM_CACHE="$XDG_STATE_HOME/nixcage/microvm"
	echo "GUEST=$TEST_TEMP_DIR/store/g-nixos=system" >"$MICROVM_CACHE"
	run microvm_cached_args
	assert_success
	assert_line "$TEST_TEMP_DIR/store/g-nixos=system"
}

@test "a workspace root with an equals sign in its path survives the host config" {
	HOST_CONFIG="$TEST_TEMP_DIR/host-config"
	echo "WORKSPACE_ROOTS=/srv/a=b:/srv/c" >"$HOST_CONFIG"
	host_read_config
	[ "$VM_WORKSPACE_ROOTS" = "/srv/a=b:/srv/c" ]
}
