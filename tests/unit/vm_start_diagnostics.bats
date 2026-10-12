#!/usr/bin/env bats
# What starting the macOS VM says when it cannot: who holds the SSH port,
# that the wait is still going, and what the VM said before it timed out.

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

stub_lsof() {
	printf '#!/usr/bin/env bash\nprintf "p%s\\nc%s\\n"\n' "$1" "$2" >"$TEST_TEMP_DIR/bin/lsof"
	chmod +x "$TEST_TEMP_DIR/bin/lsof"
}

@test "the port's holder is named by pid and command" {
	stub_lsof 4242 qemu-system-aarch64
	run port_holder 22022
	[ "$output" = "4242 qemu-system-aarch64" ]
}

@test "a port held by a qemu is called a lost nixcage VM, with the pid to stop" {
	stub_lsof 4242 qemu-system-aarch64
	run vm_port_refusal 22022
	[[ "$output" == *"4242"* ]]
	[[ "$output" == *"kill 4242"* ]]
}

@test "a port held by something else names it and points at sshPort" {
	stub_lsof 77 nginx
	run vm_port_refusal 22022
	[[ "$output" == *"nginx"* ]]
	[[ "$output" == *sshPort* ]]
	[[ "$output" != *kill* ]]
}

@test "a holder lsof cannot name still gets the refusal" {
	printf '#!/usr/bin/env bash\nexit 1\n' >"$TEST_TEMP_DIR/bin/lsof"
	chmod +x "$TEST_TEMP_DIR/bin/lsof"
	run vm_port_refusal 22022
	[[ "$output" == *"22022 is already in use"* ]]
	[[ "$output" == *sshPort* ]]
}

# The wait drives a stubbed ssh that never connects, and a VM that stays up.
wait_for_ssh_that_never_comes() {
	write_cache
	printf '#!/usr/bin/env bash\nexit 255\n' >"$TEST_TEMP_DIR/bin/ssh"
	printf '#!/usr/bin/env bash\necho microvm-run\n' >"$TEST_TEMP_DIR/bin/ps"
	chmod +x "$TEST_TEMP_DIR/bin/ssh" "$TEST_TEMP_DIR/bin/ps"
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	printf 'line %s\n' $(seq 1 40) >"$XDG_STATE_HOME/nixcage/vm.log"
	NIXCAGE_SSH_TIMEOUT="$1" NIXCAGE_SSH_PROGRESS="$2" run bash -c \
		'source "$1"; vm_wait_for_ssh' _ "$NIXCAGE_BIN"
}

@test "a wait that times out shows the end of the VM's log" {
	wait_for_ssh_that_never_comes 1 30
	[ "$status" -ne 0 ]
	[[ "$output" == *"Timed out"* ]]
	[[ "$output" == *"line 40"* ]]
	[[ "$output" != *"line 1"$'\n'* ]]
}

@test "a long wait says it is still waiting" {
	wait_for_ssh_that_never_comes 5 1
	[[ "$output" == *"Still waiting"* ]]
}
