#!/usr/bin/env bats
# A session entered with --shell gets the devShell that names, rather than the
# project's default one, and is refused when that shell is not there.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	PROJECT="$TEST_TEMP_DIR/project"
	mkdir -p "$STUB_DIR" "$PROJECT"
	PATH="$STUB_DIR:$PATH"
	export PATH NIXCAGE_PROJECT="$PROJECT"
	export HOME="$TEST_TEMP_DIR/home"
	mkdir -p "$HOME"
	source "$NIXCAGE_ROOT/modules/dev-shell.sh"
}

teardown() {
	teardown_temp_dir
}

# Stand in for nix: 'eval' prints $1, 'develop' logs its arguments.
stub_nix() {
	cat >"$STUB_DIR/nix" <<EOF
#!/usr/bin/env bash
case "\$1" in
eval)
	printf '%s\n' "\$@" >"$TEST_TEMP_DIR/expr"
	printf '%s' '${1:-yes}'
	exit ${2:-0}
	;;
develop)
	printf '%s\n' "nix \$*" >>"$TEST_TEMP_DIR/calls"
	shift
	while [ \$# -gt 0 ]; do
		if [ "\$1" = --command ]; then
			shift
			exec "\$@"
		fi
		shift
	done
	echo "entered a shell"
	;;
esac
EOF
	chmod +x "$STUB_DIR/nix"
}

@test "a named shell is asked about by name, not as the default" {
	stub_nix yes 0
	run nixcage_has_dev_shell "$PROJECT" backend-jvm
	[ "$status" -eq 0 ]
	expr_text="$(cat "$TEST_TEMP_DIR/expr")"
	[[ "$expr_text" == *'"backend-jvm"'* ]]
	[[ "$expr_text" != *'? default'* ]]
}

@test "a project missing the named shell is reported as missing, not broken" {
	stub_nix no 0
	run nixcage_has_dev_shell "$PROJECT" backend-jvm
	[ "$status" -eq 1 ]
}

@test "a flake that fails to evaluate stays distinguishable for a named shell" {
	stub_nix "" 1
	run nixcage_has_dev_shell "$PROJECT" backend-jvm
	[ "$status" -eq 2 ]
}

@test "a role with a declared shell enters that shell" {
	stub_nix yes 0
	NIXCAGE_SHELL=backend-jvm run nixcage_enter_shell echo hello
	[ "$status" -eq 0 ]
	[[ "$output" == *hello* ]]
	grep -q "nix develop $PROJECT#backend-jvm" "$TEST_TEMP_DIR/calls"
}

@test "a declared shell wins over the project's .envrc" {
	touch "$PROJECT/.envrc"
	stub_nix yes 0
	cat >"$STUB_DIR/direnv" <<'EOF'
#!/usr/bin/env bash
echo "ran direnv"
EOF
	chmod +x "$STUB_DIR/direnv"
	NIXCAGE_SHELL=backend-jvm run nixcage_enter_shell echo hello
	[ "$status" -eq 0 ]
	[[ "$output" != *"ran direnv"* ]]
}

@test "a declared shell the project does not define is refused, not substituted" {
	stub_nix no 0
	NIXCAGE_SHELL=backend-jvm run nixcage_enter_shell echo hello
	[ "$status" -ne 0 ]
	[[ "$output" != *hello* ]]
	[[ "$output" == *backend-jvm* ]]
}

@test "the refusal names the shells the project does offer" {
	cat >"$STUB_DIR/nix" <<EOF
#!/usr/bin/env bash
case "\$1" in
eval)
	case "\$*" in
	# No trailing newline: this is what a --raw eval actually prints.
	*attrNames*) printf 'frontend\nops' ;;
	*) printf 'no' ;;
	esac
	;;
esac
EOF
	chmod +x "$STUB_DIR/nix"
	NIXCAGE_SHELL=backend-jvm run nixcage_enter_shell echo hello
	[ "$status" -ne 0 ]
	[[ "$output" == *frontend* ]]
	[[ "$output" == *ops* ]]
}

@test "an unset shell leaves the ordinary default-shell behaviour alone" {
	stub_nix yes 0
	run nixcage_enter_shell echo hello
	[ "$status" -eq 0 ]
	grep -q 'nix develop --command' "$TEST_TEMP_DIR/calls"
	expr_text="$(cat "$TEST_TEMP_DIR/expr")"
	[[ "$expr_text" == *'? default'* ]]
}

@test "a shell name that is not an attribute name is refused" {
	run nixcage_shell_name_ok backend-jvm
	[ "$status" -eq 0 ]
	run nixcage_shell_name_ok jvm_1
	[ "$status" -eq 0 ]
	for bad in "" "a b" "a#b" "-lead" "a'b" "../x" 'a$b'; do
		run nixcage_shell_name_ok "$bad"
		[ "$status" -ne 0 ]
	done
}
