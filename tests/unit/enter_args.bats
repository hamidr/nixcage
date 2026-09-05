#!/usr/bin/env bats
# The options `enter` is parameterised with (ADR-009). This is the exported
# interface, so what it accepts and what it refuses is asserted directly rather
# than inferred from the session that comes out of it.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/bind.sh
	source "$NIXCAGE_ROOT/modules/bind.sh"
	# shellcheck source=../../modules/enter-args.sh
	source "$NIXCAGE_ROOT/modules/enter-args.sh"
}

teardown() {
	teardown_temp_dir
}

@test "a session with no options is the ordinary one" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_UID" ]
	[ -z "$NIXCAGE_ENTER_USER" ]
	[ -z "$NIXCAGE_ENTER_HOME" ]
	[ "${#NIXCAGE_ENTER_BINDS[@]}" -eq 0 ]
	[ "${#NIXCAGE_ENTER_ENV[@]}" -eq 0 ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
	[ "${NIXCAGE_ENTER_ARGV[1]}" = /srv/myproj ]
}

@test "the uid, the login name and the home are each taken" {
	nixcage_enter_parse --uid 700000 --user builder --home /var/lib/nixcage/homes/x \
		acme-builder /srv/w
	[ "$NIXCAGE_ENTER_UID" = 700000 ]
	[ "$NIXCAGE_ENTER_USER" = builder ]
	[ "$NIXCAGE_ENTER_HOME" = /var/lib/nixcage/homes/x ]
}

@test "binds keep the order they were asked for" {
	# nspawn applies them in order, so a caller mapping one path inside
	# another has to be able to say which comes first.
	nixcage_enter_parse --bind /a:/workspace/a --bind-ro /b:/workspace/b \
		--bind /c:/workspace/c n /srv/w
	[ "${NIXCAGE_ENTER_BINDS[0]}" = "--bind=/a:/workspace/a" ]
	[ "${NIXCAGE_ENTER_BINDS[1]}" = "--bind-ro=/b:/workspace/b" ]
	[ "${NIXCAGE_ENTER_BINDS[2]}" = "--bind=/c:/workspace/c" ]
}

@test "environment entries keep their order too" {
	nixcage_enter_parse --setenv A=1 --setenv B=2 n /srv/w
	[ "${NIXCAGE_ENTER_ENV[0]}" = "--setenv=A=1" ]
	[ "${NIXCAGE_ENTER_ENV[1]}" = "--setenv=B=2" ]
}

@test "a refused bind stops the parse rather than being dropped" {
	run nixcage_enter_parse --bind /a:/nix/store n /srv/w
	assert_failure
	assert_output --partial "nothing may be mounted at /nix/store"
}

@test "a refused environment name stops the parse too" {
	run nixcage_enter_parse --setenv "not a name=1" n /srv/w
	assert_failure
}

@test "an agent socket and refusing one are mutually exclusive" {
	# Resolving them silently would decide a security property by argument
	# order, which is the one thing this must not do.
	run nixcage_enter_parse --auth-sock /tmp/a.sock --no-agent n /srv/w
	assert_failure
	assert_output --partial "mutually exclusive"
	run nixcage_enter_parse --no-agent --auth-sock /tmp/a.sock n /srv/w
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "either one on its own is fine" {
	nixcage_enter_parse --auth-sock /tmp/a.sock n /srv/w
	[ "$NIXCAGE_ENTER_AUTH_SOCK" = /tmp/a.sock ]
	[ -z "$NIXCAGE_ENTER_NO_AGENT" ]
	nixcage_enter_parse --no-agent n /srv/w
	[ -n "$NIXCAGE_ENTER_NO_AGENT" ]
	[ -z "$NIXCAGE_ENTER_AUTH_SOCK" ]
}

@test "a uid that is not a number is refused" {
	run nixcage_enter_parse --uid root n /srv/w
	assert_failure
	assert_output --partial "not a uid: root"
}

@test "a home that could climb out of the state directory is refused" {
	run nixcage_enter_parse --home /var/lib/nixcage/homes/../../../etc n /srv/w
	assert_failure
	assert_output --partial "not a usable home path"
}

@test "a session command spelt like one of our own flags is left alone" {
	# Options precede the positionals, so everything past the first
	# non-option word belongs to the caller whatever it looks like.
	nixcage_enter_parse --uid 700000 n /srv/w agent --no-agent --setenv X
	[ "$NIXCAGE_ENTER_UID" = 700000 ]
	[ -z "$NIXCAGE_ENTER_NO_AGENT" ]
	[ "${#NIXCAGE_ENTER_ENV[@]}" -eq 0 ]
	[ "${NIXCAGE_ENTER_ARGV[2]}" = agent ]
	[ "${NIXCAGE_ENTER_ARGV[3]}" = "--no-agent" ]
	[ "${NIXCAGE_ENTER_ARGV[5]}" = X ]
}

@test "a session command survives spaces and newlines" {
	nixcage_enter_parse n /srv/w sh -c "$(printf 'echo one\necho two')"
	[ "${NIXCAGE_ENTER_ARGV[4]}" = "$(printf 'echo one\necho two')" ]
	[ "${#NIXCAGE_ENTER_ARGV[@]}" -eq 5 ]
}

@test "a parse does not inherit what the last one produced" {
	nixcage_enter_parse --uid 700000 --bind /a:/workspace/a n /srv/w
	nixcage_enter_parse n /srv/w
	[ -z "$NIXCAGE_ENTER_UID" ]
	[ "${#NIXCAGE_ENTER_BINDS[@]}" -eq 0 ]
}
