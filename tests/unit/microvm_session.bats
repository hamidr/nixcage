#!/usr/bin/env bats
# The host side of a microvm session (ADR-019): what is refused before
# anything boots, the watch that ends a boot nobody heard from, and the
# status enter reports from what the guest left behind.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/microvm-session.sh
	source "$NIXCAGE_ROOT/modules/microvm-session.sh"
}

teardown() {
	teardown_temp_dir
}

# nixcage_microvm_refusal <os> <guest> <kvm> <vmspawn version>: the reason, or nothing

@test "a host with a guest, kvm and a vmspawn of 261 refuses nothing" {
	run nixcage_microvm_refusal linux /nix/store/abc-guest "$TEST_TEMP_DIR" 261
	assert_success
	assert_output ""
}

@test "macOS is refused: the shared VM cannot nest another" {
	run nixcage_microvm_refusal macos /nix/store/abc-guest "$TEST_TEMP_DIR" 261
	assert_failure
	assert_output "nixcage: --substrate microvm is not available on macOS"
}

@test "a host that built no guest is refused before vmspawn is looked for" {
	run nixcage_microvm_refusal linux "" "$TEST_TEMP_DIR" 261
	assert_failure
	assert_output "nixcage: this host builds no microvm guest: set nixcage.microvm.enable"
}

@test "no kvm is refused: a guest without it would boot, slowly, and every bound would lie" {
	run nixcage_microvm_refusal linux /nix/store/abc-guest "$TEST_TEMP_DIR/no-such" 261
	assert_failure
	assert_output "nixcage: no /dev/kvm on this host"
}

@test "a vmspawn older than 261 or absent is refused by its version" {
	run nixcage_microvm_refusal linux /nix/store/abc-guest "$TEST_TEMP_DIR" 260
	assert_failure
	assert_output "nixcage: systemd-vmspawn 260 is older than 261"
	run nixcage_microvm_refusal linux /nix/store/abc-guest "$TEST_TEMP_DIR" ""
	assert_failure
	assert_output "nixcage: systemd-vmspawn not found"
}

# nixcage_microvm_outcome <ready marker> <exit file> <stopped marker>: the status enter exits with

@test "the status the guest wrote and synced is what enter exits with" {
	echo 7 >"$TEST_TEMP_DIR/exit"
	run nixcage_microvm_outcome "$TEST_TEMP_DIR/ready" "$TEST_TEMP_DIR/exit" "$TEST_TEMP_DIR/stopped"
	assert_success
	assert_output 7
}

@test "a boot the watch had to stop is 124, and says so" {
	: >"$TEST_TEMP_DIR/stopped"
	run nixcage_microvm_outcome "$TEST_TEMP_DIR/ready" "$TEST_TEMP_DIR/exit" "$TEST_TEMP_DIR/stopped"
	assert_success
	assert_output --partial "session did not become ready"
	assert_line --index 0 124
}

@test "a guest that finished before the watch heard from it is read like any other exit" {
	# The model's one change to the design: the status is there, so the
	# timeout is not the story.
	echo 3 >"$TEST_TEMP_DIR/exit"
	: >"$TEST_TEMP_DIR/stopped"
	run nixcage_microvm_outcome "$TEST_TEMP_DIR/ready" "$TEST_TEMP_DIR/exit" "$TEST_TEMP_DIR/stopped"
	assert_line --index 0 3
}

@test "a guest that ended without a status is 255, never a success" {
	: >"$TEST_TEMP_DIR/ready"
	run nixcage_microvm_outcome "$TEST_TEMP_DIR/ready" "$TEST_TEMP_DIR/exit" "$TEST_TEMP_DIR/stopped"
	assert_line --index 0 255
	assert_output --partial "session ended without status"
	echo "not a number" >"$TEST_TEMP_DIR/exit"
	run nixcage_microvm_outcome "$TEST_TEMP_DIR/ready" "$TEST_TEMP_DIR/exit" "$TEST_TEMP_DIR/stopped"
	assert_line --index 0 255
}

# nixcage_microvm_watch <ready marker> <name> <timeout> <stopped marker>: stops a
# guest nobody heard from within the timeout. machinectl is what stops it, so
# a stub on PATH records the call.

@test "the watch stops a guest that never became ready, and marks that it did" {
	mkdir -p "$TEST_TEMP_DIR/bin"
	printf '#!/bin/sh\necho "$@" >>"%s/machinectl.calls"\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/machinectl"
	chmod +x "$TEST_TEMP_DIR/bin/machinectl"
	PATH="$TEST_TEMP_DIR/bin:$PATH" nixcage_microvm_watch "$TEST_TEMP_DIR/ready" myproj 1 "$TEST_TEMP_DIR/stopped"
	[ -f "$TEST_TEMP_DIR/stopped" ]
	[ "$(cat "$TEST_TEMP_DIR/machinectl.calls")" = "terminate myproj" ]
}

@test "the watch stops nothing once the guest is ready" {
	mkdir -p "$TEST_TEMP_DIR/bin"
	printf '#!/bin/sh\necho "$@" >>"%s/machinectl.calls"\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/machinectl"
	chmod +x "$TEST_TEMP_DIR/bin/machinectl"
	: >"$TEST_TEMP_DIR/ready"
	PATH="$TEST_TEMP_DIR/bin:$PATH" nixcage_microvm_watch "$TEST_TEMP_DIR/ready" myproj 1 "$TEST_TEMP_DIR/stopped"
	[ ! -f "$TEST_TEMP_DIR/stopped" ]
	[ ! -f "$TEST_TEMP_DIR/machinectl.calls" ]
}

# nixcage_microvm_ssh_target <name>: the key and the address machined
# recorded for the VM, one per line. machinectl answers, so a stub does here.

@test "the ssh target is what machined recorded for the VM" {
	mkdir -p "$TEST_TEMP_DIR/bin"
	cat >"$TEST_TEMP_DIR/bin/machinectl" <<'STUB'
#!/bin/sh
case "$*" in
*SSHPrivateKeyPath*) echo /run/systemd/vmspawn/myproj/ed25519 ;;
*SSHAddress*) echo vsock/1340938338 ;;
esac
STUB
	chmod +x "$TEST_TEMP_DIR/bin/machinectl"
	PATH="$TEST_TEMP_DIR/bin:$PATH" run nixcage_microvm_ssh_target myproj
	assert_success
	assert_line --index 0 /run/systemd/vmspawn/myproj/ed25519
	assert_line --index 1 vsock/1340938338
}

@test "a VM machined has no address for is not reachable, and says so" {
	mkdir -p "$TEST_TEMP_DIR/bin"
	printf '#!/bin/sh\nexit 1\n' >"$TEST_TEMP_DIR/bin/machinectl"
	chmod +x "$TEST_TEMP_DIR/bin/machinectl"
	PATH="$TEST_TEMP_DIR/bin:$PATH" run nixcage_microvm_ssh_target myproj
	assert_failure
	assert_output --partial "myproj has no ssh address: not a running microvm cage"
}

# nixcage_exec_microvm_words <key> <address> <uid> <gid> <tty> [--setenv=K=V...] -- [cmd...]
# The words, one per line: ssh over vsock with the key vmspawn made, then
# one remote line that becomes the uid in the workspace with the given
# environment and nothing else.

@test "exec on a microvm cage is ssh over vsock, becoming the session's uid in the workspace" {
	NIXCAGE_EXEC_ENV=/nix/store/x-coreutils/bin/env NIXCAGE_EXEC_SETPRIV=/nix/store/y-util-linux/bin/setpriv
	run nixcage_exec_microvm_words /run/systemd/vmspawn/myproj/ed25519 vsock/1340938338 700001 700001 "" \
		--setenv=HOME=/home/agent --setenv=PATH=/nix/store/p/bin -- git status
	assert_success
	assert_line --index 0 ssh
	refute_line "-t"
	assert_line "-i"
	assert_line "/run/systemd/vmspawn/myproj/ed25519"
	assert_line "root@vsock/1340938338"
	assert_line --index -1 "cd /workspace && exec /nix/store/y-util-linux/bin/setpriv --reuid=700001 --regid=700001 --clear-groups -- /nix/store/x-coreutils/bin/env -i HOME=/home/agent PATH=/nix/store/p/bin git status"
}

@test "with a tty, ssh is asked for one, and no command means the cage's shell" {
	NIXCAGE_EXEC_ENV=env NIXCAGE_EXEC_SETPRIV=setpriv
	run nixcage_exec_microvm_words /k vsock/1 1000 100 1 --setenv=HOME=/home/nixcage --
	assert_success
	assert_line "-t"
	assert_line --index -1 "cd /workspace && exec setpriv --reuid=1000 --regid=100 --clear-groups -- env -i HOME=/home/nixcage bash"
}

@test "a word with a space or a quote reaches the guest as one word" {
	NIXCAGE_EXEC_ENV=env NIXCAGE_EXEC_SETPRIV=setpriv
	run nixcage_exec_microvm_words /k vsock/1 1000 100 "" --setenv=MSG='a b' -- sh -c 'echo "x y"'
	assert_line --index -1 "cd /workspace && exec setpriv --reuid=1000 --regid=100 --clear-groups -- env -i MSG=a\\ b sh -c echo\\ \\\"x\\ y\\\""
}

# nixcage_agent_forward_words <key> <address> <host socket>: the ssh that
# carries the host's agent into the guest as a socket, no key with it.

@test "the agent reaches the guest as a remote socket forward over vsock ssh, and nothing else" {
	run nixcage_agent_forward_words /run/systemd/vmspawn/myproj/ed25519 vsock/1340938338 /run/user/1000/ssh-agent.sock
	assert_success
	assert_line --index 0 ssh
	assert_line "-N"
	assert_line "-o"
	assert_line "ExitOnForwardFailure=yes"
	assert_line "-R"
	assert_line "/run/ssh-agent.sock:/run/user/1000/ssh-agent.sock"
	assert_line "root@vsock/1340938338"
	refute_line "-A"
}

# nixcage_microvm_env_write <file> [--setenv=K=V...] / nixcage_microvm_env_read <file>:
# what enter was asked by --setenv, kept beside the record for exec, root
# only, since a value may be a token and the record is readable by all.

@test "the asked environment is kept for exec as it was given, values with newlines included, and read back" {
	nixcage_microvm_env_write "$TEST_TEMP_DIR/env" --setenv=TOKEN=secret --setenv=MSG=$'two\nlines'
	[ "$(stat -c %a "$TEST_TEMP_DIR/env")" = 600 ]
	# bash drops NULs from a substitution, so the words are read as exec
	# reads them, into an array.
	local -a words=()
	mapfile -d '' -t words < <(nixcage_microvm_env_read "$TEST_TEMP_DIR/env")
	[ "${#words[@]}" -eq 2 ]
	[ "${words[0]}" = "--setenv=TOKEN=secret" ]
	[ "${words[1]}" = $'--setenv=MSG=two\nlines' ]
}

@test "a session asked nothing keeps an empty file, and exec reads nothing from it or from none" {
	nixcage_microvm_env_write "$TEST_TEMP_DIR/env"
	run nixcage_microvm_env_read "$TEST_TEMP_DIR/env"
	assert_success
	assert_output ""
	run nixcage_microvm_env_read "$TEST_TEMP_DIR/none"
	assert_success
	assert_output ""
}


# A vsock address resolves through systemd-ssh-proxy, and nothing else does.
# NixOS includes systemd's own snippet in ssh_config; a host that declared
# nothing has no such drop-in, so the snippet is named on the command line and
# the transport works the same on every host (ADR-023).

@test "ssh is given systemd's own proxy configuration for a vsock address" {
	NIXCAGE_SSH_CONFIG=/nix/store/s-systemd/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf
	NIXCAGE_EXEC_ENV=env NIXCAGE_EXEC_SETPRIV=setpriv
	run nixcage_exec_microvm_words /k vsock/1 1000 100 "" --
	assert_success
	assert_line "-F"
	assert_line "/nix/store/s-systemd/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf"
}

@test "the agent forward is given the same configuration" {
	NIXCAGE_SSH_CONFIG=/nix/store/s-systemd/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf
	run nixcage_agent_forward_words /k vsock/1 /run/user/1000/ssh-agent.sock
	assert_success
	assert_line "-F"
	assert_line "/nix/store/s-systemd/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf"
}

# A host whose ssh already resolves the address needs nothing named, and the
# words stay what they were.
@test "with no configuration named, ssh is left to the host's own" {
	NIXCAGE_SSH_CONFIG=""
	NIXCAGE_EXEC_ENV=env NIXCAGE_EXEC_SETPRIV=setpriv
	run nixcage_exec_microvm_words /k vsock/1 1000 100 "" --
	assert_success
	refute_line "-F"
}

# A microvm cage's scope exists before its guest's sshd answers, so an exec
# as soon as status says running met "Connection reset by peer" for about
# four seconds of every boot (found 2026-09-24). exec waits for a probe to
# get through before it runs the command, which therefore runs once.

# A probe that fails the given number of times, then succeeds.
flaky_probe() {
	local failures="$1"
	cat >"$TEST_TEMP_DIR/probe" <<EOF2
#!/usr/bin/env bash
n=\$(cat "$TEST_TEMP_DIR/tries" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$TEST_TEMP_DIR/tries"
[ "\$n" -ge $failures ]
EOF2
	chmod +x "$TEST_TEMP_DIR/probe"
}

@test "an exec waits until the guest answers" {
	flaky_probe 2
	NIXCAGE_MICROVM_AWAIT_INTERVAL=0 run nixcage_microvm_await 5 "$TEST_TEMP_DIR/probe"
	assert_success
	[ "$(cat "$TEST_TEMP_DIR/tries")" -eq 3 ]
}

@test "a guest that is already up is asked once" {
	flaky_probe 0
	NIXCAGE_MICROVM_AWAIT_INTERVAL=0 run nixcage_microvm_await 5 "$TEST_TEMP_DIR/probe"
	assert_success
	[ "$(cat "$TEST_TEMP_DIR/tries")" -eq 1 ]
}

@test "a guest that never answers is given up on, saying so" {
	flaky_probe 99
	NIXCAGE_MICROVM_AWAIT_INTERVAL=0 run nixcage_microvm_await 3 "$TEST_TEMP_DIR/probe"
	assert_failure
	assert_output --partial "did not answer within 3"
}
