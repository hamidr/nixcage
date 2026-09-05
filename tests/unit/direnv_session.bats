#!/usr/bin/env bats
# A project that configures itself with .envrc is entered through direnv,
# the way it would be on the host.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	PROJECT="$TEST_TEMP_DIR/project"
	mkdir -p "$STUB_DIR" "$PROJECT"
	PATH="$STUB_DIR:$PATH"
	export PATH NIXCAGE_PROJECT="$PROJECT"
	export HOME="$TEST_TEMP_DIR/home"
	export NIXCAGE_DIRENVRC="$TEST_TEMP_DIR/nix-direnv/direnvrc"
	mkdir -p "$HOME" "$(dirname "$NIXCAGE_DIRENVRC")"
	touch "$NIXCAGE_DIRENVRC"
	source "$NIXCAGE_ROOT/modules/dev-shell.sh"
}

teardown() {
	teardown_temp_dir
}

stub_direnv() {
	cat >"$STUB_DIR/direnv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "direnv \$*" >>"$TEST_TEMP_DIR/calls"
case "\$1" in
exec) shift 2; exec "\$@" ;;
esac
exit ${1:-0}
EOF
	chmod +x "$STUB_DIR/direnv"
}

stub_nix_develop() {
	cat >"$STUB_DIR/nix" <<'EOF'
#!/usr/bin/env bash
case "$1" in
eval) printf 'yes' ;;
develop) echo "ran nix develop" ;;
esac
EOF
	chmod +x "$STUB_DIR/nix"
}

@test "a project with .envrc is entered through direnv, not nix develop" {
	touch "$PROJECT/.envrc"
	stub_direnv
	stub_nix_develop
	run nixcage_enter_shell echo hello
	[ "$status" -eq 0 ]
	[[ "$output" == *hello* ]]
	[[ "$output" != *"ran nix develop"* ]]
	grep -q "direnv exec" "$TEST_TEMP_DIR/calls"
}

@test "the .envrc is allowed first, or direnv would refuse to load it" {
	touch "$PROJECT/.envrc"
	stub_direnv
	run nixcage_enter_shell echo hello
	grep -q "direnv allow" "$TEST_TEMP_DIR/calls"
}

@test "nix-direnv is wired in so use flake caches instead of re-evaluating" {
	touch "$PROJECT/.envrc"
	stub_direnv
	run nixcage_enter_shell echo hello
	grep -q "$NIXCAGE_DIRENVRC" "$HOME/.config/direnv/direnvrc"
}

@test "seeding direnvrc twice does not duplicate the source line" {
	touch "$PROJECT/.envrc"
	stub_direnv
	run nixcage_enter_shell echo hello
	run nixcage_enter_shell echo hello
	[ "$(grep -c "$NIXCAGE_DIRENVRC" "$HOME/.config/direnv/direnvrc")" -eq 1 ]
}

@test "a project without .envrc still takes the devShell path" {
	stub_direnv
	stub_nix_develop
	run nixcage_enter_shell
	[[ "$output" == *"ran nix develop"* ]]
	[ ! -f "$TEST_TEMP_DIR/calls" ]
}

@test "a failing .envrc is not replaced by a bare shell" {
	touch "$PROJECT/.envrc"
	cat >"$STUB_DIR/direnv" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == exec ]] && { echo "envrc broke" >&2; exit 1; }
exit 0
EOF
	chmod +x "$STUB_DIR/direnv"
	stub_nix_develop
	run nixcage_enter_shell echo hello
	[ "$status" -ne 0 ]
	[[ "$output" != *hello* ]]
	[[ "$output" != *"ran nix develop"* ]]
}

@test "seeding the direnvrc needs no tool the base userland lacks" {
	# A session that enters no devShell has bash, nix, git and little else:
	# no grep, no sed. A seed that shelled out to one would append the same
	# line on every entry.
	touch "$PROJECT/.envrc"
	stub_direnv
	local tool
	for tool in grep sed awk; do
		printf '#!/usr/bin/env bash\nexit 127\n' >"$STUB_DIR/$tool"
		chmod +x "$STUB_DIR/$tool"
	done
	run nixcage_enter_shell echo hello
	run nixcage_enter_shell echo hello
	[ "$(wc -l <"$HOME/.config/direnv/direnvrc")" -eq 1 ]
}
