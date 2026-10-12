#!/usr/bin/env bats
# nixcage_has_dev_shell decides whether a project can be entered through
# 'nix develop', and must tell a missing devShell apart from a broken flake.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	PROJECT="$TEST_TEMP_DIR/project"
	mkdir -p "$STUB_DIR" "$PROJECT"
	# These are the flake-directory cases; the directory without one is
	# flakeless_project.bats (ADR-021).
	touch "$PROJECT/flake.nix"
	PATH="$STUB_DIR:$PATH"
	export PATH NIXCAGE_PROJECT="$PROJECT"
	source "$NIXCAGE_ROOT/modules/dev-shell.sh"
}

teardown() {
	teardown_temp_dir
}

# Stand in for nix eval: $1 is what it prints, $2 the exit status.
stub_nix() {
	cat >"$STUB_DIR/nix" <<EOF
#!/usr/bin/env bash
printf '%s' '$1'
exit ${2:-0}
EOF
	chmod +x "$STUB_DIR/nix"
}

@test "reports a devShell when the flake provides one" {
	stub_nix yes 0
	run nixcage_has_dev_shell /workspace
	[ "$status" -eq 0 ]
}

@test "reports no devShell when the flake evaluates without one" {
	stub_nix no 0
	run nixcage_has_dev_shell /workspace
	[ "$status" -eq 1 ]
}

@test "distinguishes a flake that fails to evaluate from a missing devShell" {
	stub_nix "" 1
	run nixcage_has_dev_shell /workspace
	[ "$status" -eq 2 ]
}

@test "asks about every attribute nix develop resolves" {
	cat >"$STUB_DIR/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_EXPR_LOG"
printf 'no'
EOF
	chmod +x "$STUB_DIR/nix"
	STUB_EXPR_LOG="$TEST_TEMP_DIR/expr" run nixcage_has_dev_shell /workspace
	expr_text="$(cat "$TEST_TEMP_DIR/expr")"
	[[ "$expr_text" == *devShells* ]]
	[[ "$expr_text" == *devShell.* || "$expr_text" == *"devShell or"* ]]
	[[ "$expr_text" == *packages* ]]
	[[ "$expr_text" == *defaultPackage* ]]
}

@test "probes the project directory it is given" {
	cat >"$STUB_DIR/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_EXPR_LOG"
printf 'yes'
EOF
	chmod +x "$STUB_DIR/nix"
	STUB_EXPR_LOG="$TEST_TEMP_DIR/expr" run nixcage_has_dev_shell /some/project
	grep -q '/some/project' "$TEST_TEMP_DIR/expr"
}

# Stand in for both probe and launch: 'nix eval' answers $NIX_ANSWER,
# 'nix develop' just reports that it ran.
stub_nix_session() {
	cat >"$STUB_DIR/nix" <<'EOF'
#!/usr/bin/env bash
case "$1" in
eval) printf '%s' "$NIX_ANSWER"; exit "${NIX_EVAL_STATUS:-0}" ;;
develop) echo "ran nix develop"; exit 0 ;;
esac
EOF
	chmod +x "$STUB_DIR/nix"
}

@test "enters the devShell when the project has one" {
	stub_nix_session
	NIX_ANSWER=yes run nixcage_enter_shell
	[ "$status" -eq 0 ]
	[[ "$output" == *"ran nix develop"* ]]
}

@test "runs the given command inside the devShell" {
	stub_nix_session
	NIX_ANSWER=yes run nixcage_enter_shell echo hello
	[[ "$output" == *"ran nix develop"* ]]
}

@test "falls back to the base shell when the project has no devShell" {
	stub_nix_session
	NIX_ANSWER=no run nixcage_enter_shell echo hello
	[ "$status" -eq 0 ]
	[[ "$output" == *hello* ]]
	[[ "$output" != *"ran nix develop"* ]]
}

@test "says so when it falls back, rather than degrading silently" {
	stub_nix_session
	NIX_ANSWER=no run nixcage_enter_shell echo hello
	[[ "$output" == *devShell* ]]
}

@test "refuses to fall back when the flake failed to evaluate" {
	stub_nix_session
	NIX_ANSWER="" NIX_EVAL_STATUS=1 run nixcage_enter_shell echo hello
	[ "$status" -ne 0 ]
	[[ "$output" != *hello* ]]
	[[ "$output" != *"ran nix develop"* ]]
}

# The probe names the project the way nix develop's command line does. A
# bare path to builtins.getFlake is a path: flake, copied whole into the
# store with everything git ignores; on a project with gigabytes of build
# output under it that took ten minutes and failed, where the git+file
# reference nix develop resolves to copies only what git tracks.

@test "a git work tree is named to getFlake as git+file" {
	git -C "$PROJECT" init -q
	run nixcage_flake_ref "$PROJECT"
	[ "$output" = "git+file://$PROJECT" ]
}

@test "a project below the top of its repository is named with dir=" {
	git -C "$PROJECT" init -q
	mkdir -p "$PROJECT/sub/proj"
	run nixcage_flake_ref "$PROJECT/sub/proj"
	[ "$output" = "git+file://$PROJECT?dir=sub/proj" ]
}

@test "a directory outside any repository is named as a path" {
	run nixcage_flake_ref "$PROJECT"
	[ "$output" = "path:$PROJECT" ]
}

@test "the probe hands getFlake the project's reference, not a bare path" {
	git -C "$PROJECT" init -q
	cat >"$STUB_DIR/nix" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$TEST_TEMP_DIR/nix-args"
printf yes
EOF
	chmod +x "$STUB_DIR/nix"
	run nixcage_has_dev_shell "$PROJECT"
	[ "$status" -eq 0 ]
	grep -qF "getFlake \"git+file://$PROJECT\"" "$TEST_TEMP_DIR/nix-args"
}
