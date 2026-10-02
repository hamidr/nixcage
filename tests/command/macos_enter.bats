#!/usr/bin/env bats
# macOS enter goes over SSH; the remote command must survive re-splitting by
# the remote shell (finding: unquoted project path and name).

load ../test_helper/common

setup() {
	setup_temp_dir
	# Stub ssh to record the remote command instead of connecting.
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/ssh-calls"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ssh"
	# A live-looking VM so ensure_vm does not try to boot one: the pid file
	# points at this shell, and a ps stub makes it look like the VM runner.
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	cat >"$TEST_TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "microvm-run"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ps"
}

teardown() {
	teardown_temp_dir
}

@test "remote enter command quotes a project path containing spaces" {
	root="$TEST_TEMP_DIR/work space"
	mkdir -p "$root/proj"
	touch "$root/proj/flake.nix"
	cat >"$XDG_STATE_HOME/nixcage/cache" <<EOF
SSH_PORT=22022
WORKSPACE_ROOTS=$root
EOF
	cd "$root/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	# The path must appear in shell-quoted form, not as bare words.
	[[ "$output" == *"work\\ space/proj"* || "$output" == *"'$root/proj'"* ]]
}

@test "remote enter forwards the agent and lets the VM name its own socket" {
	root="$TEST_TEMP_DIR/src"
	mkdir -p "$root/proj"
	touch "$root/proj/flake.nix"
	write_cache 22022 "$root"
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	cd "$root/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	# -A forwards the agent; the socket path is the VM's, so it stays
	# unexpanded here and is resolved by the remote shell.
	[[ "$output" == *" -A "* ]]
	[[ "$output" == *'--auth-sock "$SSH_AUTH_SOCK"'* ]]
}

@test "remote enter does not forward an agent that does not exist" {
	root="$TEST_TEMP_DIR/src"
	mkdir -p "$root/proj"
	touch "$root/proj/flake.nix"
	write_cache 22022 "$root"
	cd "$root/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	[[ "$output" != *" -A "* ]]
	[[ "$output" != *--auth-sock* ]]
}

# Run the CLI with a pseudo-terminal on stdin and stdout, as a person at a
# shell has. util-linux and BSD spell script(1) differently.
run_nixcage_on_tty() {
	local cmd
	cmd="$(printf '%q ' bash "$NIXCAGE_BIN" "$@")"
	if script --version >/dev/null 2>&1; then
		run script -qec "$cmd" /dev/null
	else
		run script -q /dev/null bash -c "$cmd"
	fi
}

@test "a command entered from a terminal gets a terminal in the cage" {
	root="$TEST_TEMP_DIR/src"
	mkdir -p "$root/proj"
	write_cache 22022 "$root"
	cd "$root/proj"
	run_nixcage_on_tty enter -- claude
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	[[ "$output" == *" -t "* ]]
}

@test "a command entered from a pipe gets no terminal, so its output stays byte-exact" {
	root="$TEST_TEMP_DIR/src"
	mkdir -p "$root/proj"
	write_cache 22022 "$root"
	cd "$root/proj"
	run_nixcage enter -- true </dev/null
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	[[ "$output" != *" -t "* ]]
}
