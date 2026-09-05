#!/usr/bin/env bats
# 'nixcage exec' runs a command as root wherever this machine's cages are.
# It is the transport a tool built on nixcage reaches nixcage-container
# through, so what it must never do is let the remote shell see a command as
# anything other than the words it was handed.

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/ssh-calls"
EOF
	cat >"$TEST_TEMP_DIR/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/sudo-calls"
EOF
	cat >"$TEST_TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "microvm-run"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ssh" "$TEST_TEMP_DIR/bin/sudo" "$TEST_TEMP_DIR/bin/ps"
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache
}

teardown() {
	teardown_temp_dir
}

ssh_calls() {
	cat "$TEST_TEMP_DIR/ssh-calls"
}

@test "a command reaches the VM as root" {
	run_nixcage exec -- nixcage-container list
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "sudo nixcage-container list"
}

@test "the separator is optional" {
	run_nixcage exec nixcage-container list
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "sudo nixcage-container list"
}

@test "a word holding spaces survives re-splitting by the remote shell" {
	# The whole line is re-split there, not only the trailing arguments, so
	# every word is quoted rather than just the ones that look like data.
	run_nixcage exec -- echo "one two"
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "one\\ two"
}

@test "a word holding a shell metacharacter is not interpreted" {
	run_nixcage exec -- echo 'a;rm -rf /'
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "a\\;rm"
}

@test "an empty argument stays one argument" {
	run_nixcage exec -- echo "" done
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "echo '' done"
}

@test "no command at all is a usage error rather than a shell in the VM" {
	run_nixcage exec
	[ "$status" -ne 0 ]
	assert_output --partial "usage: nixcage exec"
}

@test "a bare separator is no command either" {
	run_nixcage exec --
	[ "$status" -ne 0 ]
	assert_output --partial "usage: nixcage exec"
}

@test "--tty asks ssh for a terminal" {
	run_nixcage exec --tty -- bash
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial " -t "
}

@test "without --tty no terminal is asked for" {
	run_nixcage exec -- true
	[ "$status" -eq 0 ]
	run ssh_calls
	refute_output --partial " -t "
}

@test "--agent forwards the caller's agent and nothing else does" {
	run_nixcage exec --agent -- git push
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial " -A "
	run_nixcage exec -- git push
	run ssh_calls
	refute_line --regexp '^-A '
}

@test "--agent carries the socket across sudo, which would otherwise clear it" {
	# The command reads SSH_AUTH_SOCK from its own environment: on macOS the
	# path is the VM's, and nothing on this side can spell it.
	run_nixcage exec --agent -- git push
	run ssh_calls
	assert_output --partial "sudo --preserve-env=SSH_AUTH_SOCK git push"
}

@test "without --agent nothing is carried across sudo" {
	run_nixcage exec -- git push
	run ssh_calls
	refute_output --partial "preserve-env"
	assert_output --partial "sudo git push"
}

@test "an option after the command belongs to the command" {
	# Options precede the command exactly as they do everywhere else, so a
	# flag of nixcage's own can never be taken out of what was handed over.
	run_nixcage exec -- some-tool --tty
	[ "$status" -eq 0 ]
	run ssh_calls
	assert_output --partial "some-tool --tty"
	refute_output --partial " -t "
}
