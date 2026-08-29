#!/usr/bin/env bats
# Regression tests for the code-review findings on the ADR-003 branch.

load ../test_helper/common

setup() {
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

# Finding: rm -rf with an unvalidated name allows path traversal.
@test "container names with path traversal are rejected" {
	run validate_container_name "../../.."
	[ "$status" -ne 0 ]
}

@test "container names with shell metacharacters are rejected" {
	run validate_container_name 'x;reboot'
	[ "$status" -ne 0 ]
}

@test "derived container names validate" {
	name="$(container_name_for "/home/me/Src/My Proj.2")"
	run validate_container_name "$name"
	[ "$status" -eq 0 ]
}

# Finding: stale vm.pid plus PID reuse yields a false "running" verdict.
@test "vm_is_running rejects a pid belonging to a non-VM process" {
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	run vm_is_running
	[ "$status" -ne 0 ]
}

# Finding: a listener already on the SSH port must be detected, not trusted.
@test "port_in_use detects a listening socket and a free port" {
	python3 -c '
import socket, time, sys, os
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(10)
' >"$TEST_TEMP_DIR/port" &
	listener=$!
	sleep 1
	port="$(cat "$TEST_TEMP_DIR/port")"
	run port_in_use "$port"
	[ "$status" -eq 0 ]
	kill "$listener" 2>/dev/null || true
	wait "$listener" 2>/dev/null || true
	run port_in_use "$port"
	[ "$status" -ne 0 ]
}
