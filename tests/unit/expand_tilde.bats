#!/usr/bin/env bats
# Unit tests for expand_tilde()

setup() {
	load '../test_helper/common'
	source_nixcage
}

@test "expand_tilde: replaces ~/path with \$HOME/path" {
	result="$(expand_tilde "~/Documents")"
	[[ "$result" == "$HOME/Documents" ]]
}

@test "expand_tilde: replaces bare ~ with \$HOME" {
	result="$(expand_tilde "~")"
	[[ "$result" == "$HOME" ]]
}

@test "expand_tilde: leaves absolute paths unchanged" {
	result="$(expand_tilde "/usr/local/bin")"
	assert_equal "$result" "/usr/local/bin"
}

@test "expand_tilde: leaves relative paths unchanged" {
	result="$(expand_tilde "relative/path")"
	assert_equal "$result" "relative/path"
}

@test "expand_tilde: handles nested tilde path" {
	result="$(expand_tilde "~/a/b/c")"
	assert_equal "$result" "$HOME/a/b/c"
}

@test "expand_tilde: does not expand tilde in middle of path" {
	result="$(expand_tilde "/some/~/path")"
	assert_equal "$result" "/some/~/path"
}

@test "expand_tilde: empty string stays empty" {
	result="$(expand_tilde "")"
	assert_equal "$result" ""
}
