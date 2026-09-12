#!/usr/bin/env bats
# A session with no nix daemon (ADR-011). Nothing in it can evaluate a flake,
# so the devShell probe would refuse every such session as a broken project;
# instead the command runs in the base userland, with whatever the caller put
# on the front of PATH, because a caller that took the daemon away is the one
# that realised the toolchain elsewhere.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
	# nix that must never be called: a session without a daemon has no store.
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

@test "given no daemon, the command runs without asking nix anything" {
	export NIXCAGE_NO_NIX_DAEMON=1
	run enter echo ran
	[ "$status" -eq 0 ]
	[ "$output" = ran ]
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
}

@test "given no daemon and an .envrc, direnv is not consulted either" {
	export NIXCAGE_NO_NIX_DAEMON=1
	printf 'use flake\n' >"$TEST_TEMP_DIR/project/.envrc"
	cat >"$STUB_DIR/direnv" <<STUB
#!/usr/bin/env bash
echo "direnv was called" >>"$TEST_TEMP_DIR/direnv-calls"
exit 1
STUB
	chmod +x "$STUB_DIR/direnv"
	run enter echo ran
	[ "$status" -eq 0 ]
	[ "$output" = ran ]
	[ ! -f "$TEST_TEMP_DIR/direnv-calls" ]
}

@test "when the caller put a prefix on PATH, the command finds it first" {
	export NIXCAGE_NO_NIX_DAEMON=1
	mkdir -p "$TEST_TEMP_DIR/profile/bin"
	printf '#!/usr/bin/env bash\necho from-the-profile\n' >"$TEST_TEMP_DIR/profile/bin/tool"
	chmod +x "$TEST_TEMP_DIR/profile/bin/tool"
	export NIXCAGE_PATH_PREFIX="$TEST_TEMP_DIR/profile/bin"
	run enter tool
	[ "$status" -eq 0 ]
	[ "$output" = from-the-profile ]
}

@test "when no daemon is asked for and no prefix given, PATH is what the session had" {
	export NIXCAGE_NO_NIX_DAEMON=1
	run enter bash -c 'echo "$PATH"'
	[ "$status" -eq 0 ]
	[ "$output" = "$PATH" ]
}

@test "with a daemon, nothing here changes: the probe still asks nix" {
	run enter echo ran
	[ -f "$TEST_TEMP_DIR/nix-calls" ]
}
