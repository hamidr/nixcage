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

# ADR-010: a principal is allocated a contiguous block, so a cage can hold
# subjects that do not trust each other equally.

@test "a principal allocated with no subjects still holds one uid" {
	run nixcage_principal_uid "$STORE" 700000 64 builder
	assert_success
	assert_output "700000"
}

@test "a block leaves room for its subjects before the next principal" {
	a="$(nixcage_principal_uid "$STORE" 700000 64 builder 3)"
	b="$(nixcage_principal_uid "$STORE" 700000 64 reviewer 3)"
	[ "$a" = "700000" ]
	[ "$b" = "700003" ]
}

@test "an entry written before blocks existed reads as a block of one" {
	printf 'legacy 700000\n' >"$STORE"
	run nixcage_principal_uid "$STORE" 700000 64 newcomer 2
	assert_success
	assert_output "700001"
}

@test "a principal keeps the block it was allocated when subjects appear later" {
	first="$(nixcage_principal_uid "$STORE" 700000 64 builder)"
	nixcage_principal_uid "$STORE" 700000 64 reviewer 4 >/dev/null
	again="$(nixcage_principal_uid "$STORE" 700000 64 builder 4)"
	[ "$first" = "$again" ]
}

@test "a block that would end outside the range is refused" {
	run nixcage_principal_uid "$STORE" 700000 4 wide 8
	assert_failure
	assert_output --partial "uid range"
}

@test "the last block that fits exactly is allocated" {
	run nixcage_principal_uid "$STORE" 700000 4 exact 4
	assert_success
	assert_output "700000"
}

@test "concurrent block allocations never overlap" {
	for principal in a b c d e f g h; do
		nixcage_principal_uid "$STORE" 700000 64 "$principal" 4 >>"$TEST_TEMP_DIR/out" &
	done
	wait
	distinct="$(sort -u "$TEST_TEMP_DIR/out" | wc -l | tr -d ' ')"
	[ "$distinct" = "8" ]
	previous=""
	while read -r uid; do
		if [ -n "$previous" ]; then
			[ "$((uid - previous))" -ge 4 ]
		fi
		previous="$uid"
	done < <(sort -n "$TEST_TEMP_DIR/out")
}

@test "a subject resolves to its own number inside the principal's block" {
	nixcage_principal_uid "$STORE" 700000 64 builder 3 >/dev/null
	run nixcage_principal_subject_uid "$STORE" builder 2
	assert_success
	assert_output "700002"
}

@test "offset zero is the principal itself" {
	nixcage_principal_uid "$STORE" 700000 64 builder 3 >/dev/null
	run nixcage_principal_subject_uid "$STORE" builder 0
	assert_success
	assert_output "700000"
}

@test "a subject outside the allocated block is refused rather than computed" {
	nixcage_principal_uid "$STORE" 700000 64 builder 2 >/dev/null
	run nixcage_principal_subject_uid "$STORE" builder 2
	assert_failure
	assert_output --partial "block"
}

@test "a principal allocated before blocks existed has no subjects" {
	printf 'legacy 700000\n' >"$STORE"
	run nixcage_principal_subject_uid "$STORE" legacy 1
	assert_failure
}

@test "a subject of an unknown principal is refused" {
	run nixcage_principal_subject_uid "$STORE" nobody 1
	assert_failure
}

@test "a declared subject resolves to its offset, and root is not one" {
	run nixcage_principal_subject_offset agent "agent watcher"
	assert_success
	assert_output "1"
	run nixcage_principal_subject_offset watcher "agent watcher"
	assert_success
	assert_output "2"
}

@test "an undeclared subject has no offset" {
	run nixcage_principal_subject_offset intruder "agent watcher"
	assert_failure
}

@test "the passwd file names every declared subject at its own uid" {
	run nixcage_principal_passwd builder "agent watcher"
	assert_success
	assert_line --index 0 "builder:x:0:0:builder:/root:/bin/sh"
	assert_line --index 1 "agent:x:1:1:agent:/home/agent:/bin/sh"
	assert_line --index 2 "watcher:x:2:2:watcher:/home/watcher:/bin/sh"
	assert_line --index 3 "nobody:x:65534:65534:nobody:/var/empty:/bin/sh"
}

@test "a subject name that could forge a passwd line is refused" {
	run nixcage_principal_passwd builder "root:x:0:0::/:/bin/sh"
	assert_failure
}

@test "the group file names every declared subject" {
	run nixcage_principal_group "agent watcher"
	assert_success
	assert_line --index 0 "root:x:0:"
	assert_line --index 1 "agent:x:1:"
	assert_line --index 2 "watcher:x:2:"
	assert_line --index 3 "nogroup:x:65534:"
}

@test "the block a uid was allocated is what the store says, not what is declared now" {
	nixcage_principal_uid "$STORE" 700000 64 builder 1 >/dev/null
	nixcage_principal_uid "$STORE" 700000 64 reviewer 4 >/dev/null
	run nixcage_principal_size_at "$STORE" 700000
	assert_success
	assert_output "1"
	run nixcage_principal_size_at "$STORE" 700001
	assert_success
	assert_output "4"
}

@test "a uid the store never allocated maps one uid and no more" {
	run nixcage_principal_size_at "$STORE" 501
	assert_success
	assert_output "1"
}

@test "an entry from before blocks existed maps one uid" {
	printf 'legacy 700000\n' >"$STORE"
	run nixcage_principal_size_at "$STORE" 700000
	assert_success
	assert_output "1"
}

@test "a subject cannot take the name cage root is entered under" {
	run nixcage_principal_passwd builder "builder"
	assert_failure
}
