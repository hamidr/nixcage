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
	nixcage_vmspawn_credential 700001 700001 /home/agent /workspace 1 10.77.0.2/24 \
		--setenv=HOME=/home/agent --setenv=MSG=$'two\nlines' -- bash -c 'echo "a b"' >"$TEST_TEMP_DIR/cred"
	nixcage_session_read "$TEST_TEMP_DIR/cred"
	[ "$SESSION_UID" = 700001 ]
	[ "$SESSION_GID" = 700001 ]
	[ "$SESSION_HOME" = /home/agent ]
	[ "$SESSION_CWD" = /workspace ]
	[ "$SESSION_TTY" = 1 ]
	[ "$SESSION_ADDRESS" = 10.77.0.2/24 ]
	[ "${#SESSION_ENV[@]}" -eq 2 ]
	[ "${SESSION_ENV[0]}" = HOME=/home/agent ]
	[ "${SESSION_ENV[1]}" = $'MSG=two\nlines' ]
	[ "${#SESSION_ARGV[@]}" -eq 3 ]
	[ "${SESSION_ARGV[0]}" = bash ]
	[ "${SESSION_ARGV[1]}" = -c ]
	[ "${SESSION_ARGV[2]}" = 'echo "a b"' ]
}

@test "a session without a tty or a placement reads as such" {
	nixcage_vmspawn_credential 1000 100 /root /workspace 0 "" -- true >"$TEST_TEMP_DIR/cred"
	nixcage_session_read "$TEST_TEMP_DIR/cred"
	[ -z "$SESSION_TTY" ]
	[ -z "$SESSION_ADDRESS" ]
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
