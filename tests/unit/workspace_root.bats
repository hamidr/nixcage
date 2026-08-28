#!/usr/bin/env bats
# check_workspace_root accepts paths under a configured root and rejects others

load ../test_helper/common

setup() {
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "path under a root passes" {
	write_cache 22022 "/home/me/Src"
	run check_workspace_root "/home/me/Src/proj"
	[ "$status" -eq 0 ]
}

@test "the root itself passes" {
	write_cache 22022 "/home/me/Src"
	run check_workspace_root "/home/me/Src"
	[ "$status" -eq 0 ]
}

@test "path under the second of two roots passes" {
	write_cache 22022 "/home/me/Src:/home/me/Work"
	run check_workspace_root "/home/me/Work/proj"
	[ "$status" -eq 0 ]
}

@test "path outside every root fails with guidance" {
	write_cache 22022 "/home/me/Src"
	run check_workspace_root "/home/me/Other/proj"
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

@test "sibling directory sharing the root as prefix fails" {
	write_cache 22022 "/home/me/Src"
	run check_workspace_root "/home/me/Srcx/proj"
	[ "$status" -ne 0 ]
}

@test "missing cache fails with rebuild guidance" {
	run check_workspace_root "/home/me/Src/proj"
	[ "$status" -ne 0 ]
	[[ "$output" == *rebuild* ]]
}
