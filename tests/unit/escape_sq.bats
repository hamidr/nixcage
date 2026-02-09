#!/usr/bin/env bats
# Unit tests for escape_sq() — single-quote escaping for injection prevention (Spec §10.3)

setup() {
	load '../test_helper/common'
	source_nixcage
}

@test "escape_sq: plain string passes through unchanged" {
	result="$(escape_sq "hello world")"
	assert_equal "$result" "hello world"
}

@test "escape_sq: escapes single quote using '\\'' idiom" {
	result="$(escape_sq "it's")"
	assert_equal "$result" "it'\\''s"
}

@test "escape_sq: escapes multiple single quotes" {
	result="$(escape_sq "it's a 'test'")"
	assert_equal "$result" "it'\\''s a '\\''test'\\''"
}

@test "escape_sq: empty string stays empty" {
	result="$(escape_sq "")"
	assert_equal "$result" ""
}

@test "escape_sq: string with only a single quote" {
	result="$(escape_sq "'")"
	# Should produce the '\'' escape sequence
	local expected="'\\''"
	assert_equal "$result" "$expected"
}

@test "escape_sq: preserves double quotes" {
	result="$(escape_sq 'say "hello"')"
	assert_equal "$result" 'say "hello"'
}

@test "escape_sq: preserves special shell characters" {
	result="$(escape_sq 'foo$bar;baz|qux')"
	assert_equal "$result" 'foo$bar;baz|qux'
}
