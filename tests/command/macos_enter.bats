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
