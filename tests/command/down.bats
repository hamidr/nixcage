#!/usr/bin/env bats
# Stopping the VM asks the guest to shut itself down first. Killing qemu
# outright leaves everything written in the last seconds unflushed, which cost
# whole worktrees before the state moved to ZFS (ADR-017).

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	# Anything the pid file points at looks like the VM runner.
	cat >"$TEST_TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "microvm-run"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ps"
	write_cache
	# The waits are real seconds; the stubs answer at once.
	export NIXCAGE_SHUTDOWN_TIMEOUT=3 NIXCAGE_KILL_TIMEOUT=2
}

teardown() {
	teardown_temp_dir
}

# A stand-in for the running VM. $1 is how it answers SIGTERM: "die" or
# "ignore" (a qemu stuck on a device is the case that needs SIGKILL).
fake_vm() {
	if [ "${1:-die}" = ignore ]; then
		bash -c 'trap "" TERM; sleep 30' &
	else
		bash -c 'sleep 30' &
	fi
	echo "$!" >"$XDG_STATE_HOME/nixcage/vm.pid"
	FAKE_VM_PID="$!"
}

# Stub ssh. With "poweroff" it kills the fake VM, the way a guest powering
# itself off ends the qemu process; with "unreachable" it fails as ssh does
# when the VM has stopped answering.
stub_ssh() {
	local behaviour="$1"
	cat >"$TEST_TEMP_DIR/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/ssh-calls"
if [ "$behaviour" = poweroff ]; then
	kill -9 "$FAKE_VM_PID" 2>/dev/null
fi
## Powering the guest off drops the connection, so a real ssh reports
## failure either way and its status can never be the signal.
exit 255
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ssh"
}

@test "down asks the guest to power itself off" {
	fake_vm
	stub_ssh poweroff
	run_nixcage down
	assert_success
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "poweroff"
}

@test "a guest that shuts down is never signalled" {
	fake_vm
	stub_ssh poweroff
	run_nixcage down
	assert_success
	refute_output --partial "stopping qemu"
	refute_output --partial "forcing kill"
	run kill -0 "$FAKE_VM_PID"
	assert_failure
}

@test "a VM that cannot be reached is stopped anyway" {
	fake_vm
	stub_ssh unreachable
	run_nixcage down
	assert_success
	assert_output --partial "stopping qemu"
	run kill -0 "$FAKE_VM_PID"
	assert_failure
}

@test "a VM that ignores the signal is killed" {
	fake_vm ignore
	stub_ssh unreachable
	run_nixcage down
	assert_success
	assert_output --partial "forcing kill"
	run kill -0 "$FAKE_VM_PID"
	assert_failure
}

@test "the pid file goes whichever way the VM stopped" {
	fake_vm
	stub_ssh poweroff
	run_nixcage down
	assert_success
	[ ! -f "$XDG_STATE_HOME/nixcage/vm.pid" ]
}

@test "a VM that is not running is not asked to shut down" {
	run_nixcage down
	assert_success
	assert_output --partial "not running"
	[ ! -f "$TEST_TEMP_DIR/ssh-calls" ]
}
