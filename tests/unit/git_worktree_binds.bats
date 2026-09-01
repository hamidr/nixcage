#!/usr/bin/env bats
# A git worktree keeps its administrative directory inside the primary
# repository, so binding only the project directory leaves git with a
# dangling pointer. nixcage_git_binds names the extra paths a session needs.

load ../test_helper/common

setup() {
	setup_temp_dir
	source "$NIXCAGE_ROOT/modules/git-worktree.sh"
}

teardown() {
	teardown_temp_dir
}

# A repository with one linked worktree, laid out the way git writes it.
make_worktree_repo() {
	local repo="$TEST_TEMP_DIR/repo" wt="$TEST_TEMP_DIR/repo.feat"
	mkdir -p "$repo/.git/worktrees/repo.feat" "$wt"
	printf '../..\n' >"$repo/.git/worktrees/repo.feat/commondir"
	printf 'gitdir: %s\n' "$repo/.git/worktrees/repo.feat" >"$wt/.git"
}

@test "an ordinary repository needs no extra bind" {
	mkdir -p "$TEST_TEMP_DIR/plain/.git"
	run nixcage_git_binds "$TEST_TEMP_DIR/plain"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "a directory that is not a repository needs no extra bind" {
	mkdir -p "$TEST_TEMP_DIR/bare"
	run nixcage_git_binds "$TEST_TEMP_DIR/bare"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "a worktree binds the primary repository's git directory" {
	make_worktree_repo
	run nixcage_git_binds "$TEST_TEMP_DIR/repo.feat"
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TEMP_DIR/repo/.git" ]
}

@test "a relative gitdir pointer resolves against the project" {
	mkdir -p "$TEST_TEMP_DIR/repo/.git/worktrees/feat" "$TEST_TEMP_DIR/repo.feat"
	printf '../..\n' >"$TEST_TEMP_DIR/repo/.git/worktrees/feat/commondir"
	printf 'gitdir: ../repo/.git/worktrees/feat\n' >"$TEST_TEMP_DIR/repo.feat/.git"
	run nixcage_git_binds "$TEST_TEMP_DIR/repo.feat"
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TEMP_DIR/repo/.git" ]
}

@test "an administrative directory outside the common directory is bound too" {
	mkdir -p "$TEST_TEMP_DIR/admin" "$TEST_TEMP_DIR/repo/.git" "$TEST_TEMP_DIR/repo.feat"
	printf '%s\n' "$TEST_TEMP_DIR/repo/.git" >"$TEST_TEMP_DIR/admin/commondir"
	printf 'gitdir: %s\n' "$TEST_TEMP_DIR/admin" >"$TEST_TEMP_DIR/repo.feat/.git"
	run nixcage_git_binds "$TEST_TEMP_DIR/repo.feat"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "$TEST_TEMP_DIR/repo/.git" ]
	[ "${lines[1]}" = "$TEST_TEMP_DIR/admin" ]
}

@test "a dangling worktree pointer fails loudly instead of entering broken" {
	mkdir -p "$TEST_TEMP_DIR/repo.feat"
	printf 'gitdir: %s/gone/.git/worktrees/feat\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/repo.feat/.git"
	run nixcage_git_binds "$TEST_TEMP_DIR/repo.feat"
	[ "$status" -ne 0 ]
	[[ "$output" == *"gone/.git/worktrees/feat"* ]]
}

@test "a .git file that is not a gitdir pointer fails loudly" {
	mkdir -p "$TEST_TEMP_DIR/odd"
	printf 'not a pointer\n' >"$TEST_TEMP_DIR/odd/.git"
	run nixcage_git_binds "$TEST_TEMP_DIR/odd"
	[ "$status" -ne 0 ]
}
