#!/usr/bin/env bats
# A named principal is allocated a uid from the declared range (ADR-004).
# What a principal is stays the caller's: nixcage only promises that one name
# always answers with one number, and that no number is ever handed out twice.

load ../test_helper/common

setup() {
	setup_temp_dir
	STORE="$TEST_TEMP_DIR/principal-uids"
	# shellcheck source=../../modules/principal-uid.sh
	source "$NIXCAGE_ROOT/modules/principal-uid.sh"
}

teardown() {
	teardown_temp_dir
}

@test "the first principal on an empty machine gets the base of the range" {
	run nixcage_principal_uid "$STORE" 700000 64 builder
	assert_success
	assert_output "700000"
}

@test "asking twice for the same principal returns the uid it already has" {
	first="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	second="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	[ "$first" = "$second" ]
}

@test "a second principal gets a different uid" {
	a="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	b="$(nixcage_principal_uid "$STORE" 700000 64 reviewer)"
	[ "$a" != "$b" ]
}

@test "an allocation survives into a later invocation" {
	first="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	nixcage_principal_uid "$STORE" 700000 64 reviewer >/dev/null
	again="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	[ "$first" = "$again" ]
}

@test "a uid is never reissued after its principal is forgotten" {
	a="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	nixcage_principal_forget "$STORE" builder
	b="$(nixcage_principal_uid "$STORE" 700000 64 newcomer)"
	[ "$a" != "$b" ]
}

@test "a forgotten principal that returns does not get its old uid back" {
	a="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	nixcage_principal_forget "$STORE" builder
	b="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	[ "$a" != "$b" ]
}

@test "exhausting the range fails loudly rather than colliding" {
	nixcage_principal_uid "$STORE" 700000 2 one >/dev/null
	nixcage_principal_uid "$STORE" 700000 2 two >/dev/null
	run nixcage_principal_uid "$STORE" 700000 2 three
	assert_failure
	assert_output --partial "uid range"
}

@test "a principal name that could escape the store is refused" {
	run nixcage_principal_uid "$STORE" 700000 64 "bad name"
	assert_failure
	run nixcage_principal_uid "$STORE" 700000 64 "../escape"
	assert_failure
}

@test "concurrent allocations never hand out the same uid" {
	for principal in a b c d e f g h; do
		nixcage_principal_uid "$STORE" 700000 64 "$principal" >>"$TEST_TEMP_DIR/out" &
	done
	wait
	total="$(wc -l <"$TEST_TEMP_DIR/out" | tr -d ' ')"
	distinct="$(sort -u "$TEST_TEMP_DIR/out" | wc -l | tr -d ' ')"
	[ "$total" = "8" ]
	[ "$distinct" = "8" ]
}

@test "a session with no principal keeps the ordinary root login" {
	run nixcage_principal_login ""
	assert_success
	assert_output "root"
}

@test "a session entered for a principal is named after it inside the cage" {
	run nixcage_principal_login builder
	assert_success
	assert_output "builder"
}

@test "the passwd line names uid 0 after the principal" {
	run nixcage_principal_passwd builder
	assert_success
	assert_line --index 0 "builder:x:0:0:builder:/root:/bin/sh"
	assert_line --index 1 "nobody:x:65534:65534:nobody:/var/empty:/bin/sh"
}

@test "an invalid principal name cannot reach the passwd file" {
	run nixcage_principal_passwd "root:x:0:0::/:/bin/sh"
	assert_failure
}
