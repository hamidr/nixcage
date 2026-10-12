#!/usr/bin/env bats
# 'nixcage rebuild' on macOS: the VM is built only for a flake that lets this
# machine in. The module refuses an empty authorizedKeys at evaluation; a list
# without this machine's key would build, boot and then time out at SSH, so
# the CLI checks that before paying for a build.

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	touch "$NIXCAGE_FLAKE/flake.nix"
	echo '[]' >"$TEST_TEMP_DIR/keys.json"
	cat >"$TEST_TEMP_DIR/bin/nix" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/nix-calls"
case "\$*" in
*authorizedKeys*) cat "$TEST_TEMP_DIR/keys.json" ;;
*sshPort*) echo 22022 ;;
*workspaceRoots*) echo '["/src"]' ;;
"eval "*) echo false ;;
esac
EOF
	chmod +x "$TEST_TEMP_DIR/bin/nix"
}

teardown() {
	teardown_temp_dir
}

KEY() { echo "$XDG_STATE_HOME/nixcage/id_ed25519"; }

authorize() {
	jq -n --arg k "$1" '[$k]' >"$TEST_TEMP_DIR/keys.json"
}

built() {
	grep -q '^build ' "$TEST_TEMP_DIR/nix-calls"
}

@test "rebuild makes this machine's key before anything asks for it" {
	run_nixcage rebuild
	[ -f "$(KEY).pub" ]
}

@test "rebuild refuses before building when authorizedKeys is empty, and prints the key to paste" {
	run_nixcage rebuild
	[ "$status" -ne 0 ]
	! built
	[[ "$output" == *"$(cut -d' ' -f1-2 "$(KEY).pub")"* ]]
	[[ "$output" == *authorizedKeys* ]]
}

@test "rebuild refuses a list holding only other machines' keys" {
	authorize "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherMachineOtherMachineOtherMachine0 other"
	run_nixcage rebuild
	[ "$status" -ne 0 ]
	! built
}

@test "rebuild builds when authorizedKeys holds this machine's key, whatever its comment" {
	mkdir -p "$(dirname "$(KEY)")"
	ssh-keygen -t ed25519 -f "$(KEY)" -N "" -q -C here
	authorize "$(cut -d' ' -f1-2 "$(KEY).pub") pasted-elsewhere"
	run_nixcage rebuild
	[ "$status" -eq 0 ]
	built
}
