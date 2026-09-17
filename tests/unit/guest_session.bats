#!/usr/bin/env bats
# The guest side of a microvm session (ADR-019): the credential the host
# wrote is read back into what the session unit runs, byte for byte.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/scope.sh
	source "$NIXCAGE_ROOT/modules/scope.sh"
	# shellcheck source=../../modules/vmspawn-args.sh
	source "$NIXCAGE_ROOT/modules/vmspawn-args.sh"
	# shellcheck source=../../modules/guest-session.sh
	source "$NIXCAGE_ROOT/modules/guest-session.sh"
}

teardown() {
	teardown_temp_dir
}

@test "what the host put in the credential is what the guest reads out" {
	nixcage_vmspawn_credential 700001 700001 /home/agent /workspace 1 10.77.0.2/24 1 10.77.0.1 \
		--setenv=HOME=/home/agent --setenv=MSG=$'two\nlines' -- bash -c 'echo "a b"' >"$TEST_TEMP_DIR/cred"
	nixcage_session_read "$TEST_TEMP_DIR/cred"
	[ "$SESSION_UID" = 700001 ]
	[ "$SESSION_GID" = 700001 ]
	[ "$SESSION_HOME" = /home/agent ]
	[ "$SESSION_CWD" = /workspace ]
	[ "$SESSION_TTY" = 1 ]
	[ "$SESSION_ADDRESS" = 10.77.0.2/24 ]
	[ "$SESSION_AGENT" = 1 ]
	[ "$SESSION_DNS" = 10.77.0.1 ]
	[ "${#SESSION_ENV[@]}" -eq 2 ]
	[ "${SESSION_ENV[0]}" = HOME=/home/agent ]
	[ "${SESSION_ENV[1]}" = $'MSG=two\nlines' ]
	[ "${#SESSION_ARGV[@]}" -eq 3 ]
	[ "${SESSION_ARGV[0]}" = bash ]
	[ "${SESSION_ARGV[1]}" = -c ]
	[ "${SESSION_ARGV[2]}" = 'echo "a b"' ]
}

@test "a session without a tty or a placement reads as such" {
	nixcage_vmspawn_credential 1000 100 /root /workspace 0 "" "" "" -- true >"$TEST_TEMP_DIR/cred"
	nixcage_session_read "$TEST_TEMP_DIR/cred"
	[ -z "$SESSION_TTY" ]
	[ -z "$SESSION_ADDRESS" ]
	[ -z "$SESSION_AGENT" ]
	[ -z "$SESSION_DNS" ]
	[ "${#SESSION_ENV[@]}" -eq 0 ]
	[ "${SESSION_ARGV[*]}" = true ]
}

@test "the guest marks itself ready, and leaves its status, as the session's own uid in its home" {
	# setpriv is what changes uid; a stub on PATH records what it was asked
	# and runs the rest, so the files land and the uid asked for is seen.
	mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/home"
	printf '#!/bin/sh\necho "$1 $2" >>"%s/setpriv.calls"; shift 4; exec "$@"\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/setpriv"
	chmod +x "$TEST_TEMP_DIR/bin/setpriv"
	SESSION_UID=700001 SESSION_GID=700001 SESSION_HOME="$TEST_TEMP_DIR/home"
	PATH="$TEST_TEMP_DIR/bin:$PATH" nixcage_session_ready
	[ -f "$TEST_TEMP_DIR/home/.nixcage-ready" ]
	PATH="$TEST_TEMP_DIR/bin:$PATH" nixcage_session_exit 7
	[ "$(cat "$TEST_TEMP_DIR/home/.nixcage-exit")" = 7 ]
	[ "$(sort -u "$TEST_TEMP_DIR/setpriv.calls")" = "--reuid=700001 --regid=700001" ]
}

# nixcage_session_agent_wait <socket> <timeout>: the forwarded agent socket
# appears when the host's ssh connects, which is after the guest is up.

@test "with an agent forwarded, the session waits for the socket and goes on once it is there" {
	SESSION_AGENT=1
	(sleep 1; : >"$TEST_TEMP_DIR/agent.sock") &
	run nixcage_session_agent_wait "$TEST_TEMP_DIR/agent.sock" 5
	assert_success
	wait
}

@test "a socket that never comes is a session without an agent, said once, not a session that never runs" {
	SESSION_AGENT=1
	run nixcage_session_agent_wait "$TEST_TEMP_DIR/agent.sock" 1
	assert_success
	assert_output --partial "no agent socket after 1s; commits cannot be signed"
}

@test "without an agent forwarded, nothing is waited for" {
	SESSION_AGENT=""
	run nixcage_session_agent_wait "$TEST_TEMP_DIR/agent.sock" 5
	assert_success
	assert_output ""
}

# nixcage_session_account <passwd> <group>: the session's uid gets a name in
# the guest, since tools ask getpwuid and git wants a committer to exist.

@test "the session's uid is given the login name it was entered with, in the guest's own files" {
	SESSION_UID=700001 SESSION_GID=700001 SESSION_HOME=/home/agent
	SESSION_ENV=(HOME=/home/agent USER=agent)
	printf 'root:x:0:0::/root:/bin/sh\n' >"$TEST_TEMP_DIR/passwd"
	printf 'root:x:0:\n' >"$TEST_TEMP_DIR/group"
	nixcage_session_account "$TEST_TEMP_DIR/passwd" "$TEST_TEMP_DIR/group"
	[ "$(tail -1 "$TEST_TEMP_DIR/passwd")" = "agent:x:700001:700001::/home/agent:/bin/sh" ]
	[ "$(tail -1 "$TEST_TEMP_DIR/group")" = "agent:x:700001:" ]
}

@test "without a login name the session is nixcage, and a uid the guest already names is left alone" {
	SESSION_UID=0 SESSION_GID=0 SESSION_HOME=/root
	SESSION_ENV=()
	printf 'root:x:0:0::/root:/bin/sh\n' >"$TEST_TEMP_DIR/passwd"
	printf 'root:x:0:\n' >"$TEST_TEMP_DIR/group"
	nixcage_session_account "$TEST_TEMP_DIR/passwd" "$TEST_TEMP_DIR/group"
	[ "$(wc -l <"$TEST_TEMP_DIR/passwd")" -eq 1 ]
	SESSION_UID=1000 SESSION_GID=100 SESSION_HOME=/home/nixcage
	nixcage_session_account "$TEST_TEMP_DIR/passwd" "$TEST_TEMP_DIR/group"
	[ "$(tail -1 "$TEST_TEMP_DIR/passwd")" = "nixcage:x:1000:100::/home/nixcage:/bin/sh" ]
}

# nixcage_session_disk <device> <mountpoint>: a persistent image handed in as
# a drive is made a filesystem once and mounted where argv keeps what
# virtiofs is too slow for. A session given no disk has no device.

@test "without a drive, no filesystem is made and nothing is mounted" {
	SESSION_UID=1000 SESSION_GID=100
	run nixcage_session_disk "$TEST_TEMP_DIR/no-such-device" "$TEST_TEMP_DIR/var-lib"
	assert_success
	assert_output ""
	[ ! -d "$TEST_TEMP_DIR/var-lib" ]
}

# nixcage_session_resolv_conf <file>: what a placed guest resolves with
# (ADR-016), as the nspawn rootfs gets it: nothing told means the guest's
# own file stands; none means empty; an address means one nameserver line.

@test "a placed session told none resolves nothing, and one told an address resolves there" {
	SESSION_DNS=none
	nixcage_session_resolv_conf "$TEST_TEMP_DIR/resolv.conf"
	[ -f "$TEST_TEMP_DIR/resolv.conf" ] && [ ! -s "$TEST_TEMP_DIR/resolv.conf" ]
	SESSION_DNS=10.77.0.1
	nixcage_session_resolv_conf "$TEST_TEMP_DIR/resolv.conf"
	[ "$(cat "$TEST_TEMP_DIR/resolv.conf")" = "nameserver 10.77.0.1" ]
}

@test "a session told nothing about resolving leaves the guest's file as it is" {
	SESSION_DNS=""
	echo "nameserver 1.1.1.1" >"$TEST_TEMP_DIR/resolv.conf"
	nixcage_session_resolv_conf "$TEST_TEMP_DIR/resolv.conf"
	[ "$(cat "$TEST_TEMP_DIR/resolv.conf")" = "nameserver 1.1.1.1" ]
}
