#!/usr/bin/env bats
# A project directory without a flake.nix (ADR-021). The probe in
# dev-shell.sh evaluates the project as a flake, which fails for such a
# directory exactly as a broken flake does, so the session has to answer the
# absence before it asks: the container is what the caller came for, and a
# directory under a workspace root is a project whether or not it declares a
# flake.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
	# nix that must never be called: there is no flake here to evaluate.
	cat >"$STUB_DIR/nix" <<STUB
#!/usr/bin/env bash
echo "nix was called: \$*" >>"$TEST_TEMP_DIR/nix-calls"
exit 1
STUB
	chmod +x "$STUB_DIR/nix"
	mkdir -p "$TEST_TEMP_DIR/project"
	export NIXCAGE_PROJECT="$TEST_TEMP_DIR/project"
	unset NIXCAGE_SHELL NIXCAGE_NO_NIX_DAEMON NIXCAGE_PATH_PREFIX
}

teardown() {
	teardown_temp_dir
}

# nixcage_enter_shell execs, so it is driven in a shell of its own.
enter() {
	bash -c "source '$NIXCAGE_ROOT/modules/dev-shell.sh'; nixcage_enter_shell \"\$@\"" _ "$@"
}

@test "given no flake.nix, the command runs in the base shell" {
	run enter echo ran
	[ "$status" -eq 0 ]
	[[ "$output" == *ran* ]]
}

@test "given no flake.nix, nix is never asked to evaluate one" {
	run enter echo ran
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
}

@test "given no flake.nix, the fallback is announced rather than silent" {
	run enter echo ran
	[[ "$output" == *flake.nix* ]]
}

@test "given no flake.nix and an .envrc, direnv still owns the environment" {
	printf 'export FROM_ENVRC=1\n' >"$TEST_TEMP_DIR/project/.envrc"
	cat >"$STUB_DIR/direnv" <<'STUB'
#!/usr/bin/env bash
case "$1" in
allow) exit 0 ;;
exec) shift 2; echo "direnv ran: $*"; exit 0 ;;
esac
STUB
	chmod +x "$STUB_DIR/direnv"
	run enter echo ran
	[ "$status" -eq 0 ]
	[[ "$output" == *"direnv ran: echo ran"* ]]
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
}

@test "a session that named a devShell in a project with no flake is refused" {
	export NIXCAGE_SHELL=rust
	run enter echo ran
	[ "$status" -ne 0 ]
	[[ "$output" != *ran* ]]
	[[ "$output" == *flake.nix* ]]
}

@test "a session that named a devShell in a project with no flake asks nix nothing" {
	export NIXCAGE_SHELL=rust
	run enter echo ran
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
}

@test "with a flake.nix, nothing here changes: the probe still asks nix" {
	touch "$TEST_TEMP_DIR/project/flake.nix"
	run enter echo ran
	[ -f "$TEST_TEMP_DIR/nix-calls" ]
}
