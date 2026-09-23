#!/usr/bin/env bats
# A Linux host with no /etc/nixcage/config still runs a cage, and the cage is
# the directory the caller is standing in (ADR-023). What the missing
# declaration costs is the roots gate, so the directories nobody means are
# refused here instead.

load ../test_helper/common

setup() {
	setup_temp_dir
	export NIXCAGE_OS=linux
	# The path the declaration would be at, deliberately never written.
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/host-config"
	export HOME="$TEST_TEMP_DIR/home"
	# What the package baked in: a nixcage the store built carries the layer
	# a session is given, since undeclared nothing else provides one.
	export NIXCAGE_CONTAINER=/nix/store/aaa-nixcage-container/bin/nixcage-container
	export NIXCAGE_PROFILE=/nix/store/bbb-nixcage-container-profile
	mkdir -p "$TEST_TEMP_DIR/bin" "$HOME"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/sudo-calls"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/sudo"
}

teardown() {
	teardown_temp_dir
}

@test "enter with no host config cages the directory it was run in" {
	mkdir -p "$TEST_TEMP_DIR/proj"
	cd "$TEST_TEMP_DIR/proj"
	run_nixcage enter
	[ "$status" -eq 0 ]
	local called
	called="$(cat "$TEST_TEMP_DIR/sudo-calls")"
	[[ "$called" == *" enter "* ]]
	[[ "$called" == *" proj-"*" $TEST_TEMP_DIR/proj"* ]]
}

@test "enter with no host config never mentions nixosModules.host" {
	mkdir -p "$TEST_TEMP_DIR/proj"
	cd "$TEST_TEMP_DIR/proj"
	run_nixcage enter
	[[ "$output" != *nixosModules.host* ]]
}

@test "enter with no host config refuses the filesystem root" {
	cd /
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a project"* ]]
}

# Asked of the gate rather than through enter, which cages $PWD: the suite
# cannot stand in a store it does not own.
@test "the store is not a project with no host config" {
	run bash -c "source '$NIXCAGE_BIN' && check_workspace_root /nix/store"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a project"* ]]
}

@test "enter with no host config refuses the home directory itself" {
	cd "$HOME"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *"home directory"* ]]
}

@test "enter with no host config refuses a directory the caller does not own" {
	[ ! -O /usr ] || skip "/usr is owned by the user running the suite"
	cd /usr
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *"not owned by you"* ]]
}

# The gate is the roots gate's, so every caller of it inherits the rule: a
# cage made from a directory has to be removable from it (ADR-023).
@test "rm without a name with no host config resolves the cage" {
	mkdir -p "$TEST_TEMP_DIR/proj"
	cd "$TEST_TEMP_DIR/proj"
	run bash -c "echo n | bash '$NIXCAGE_BIN' rm"
	[ "$status" -eq 0 ]
	[[ "$output" == *proj-* ]]
	[[ "$output" == *Aborted* ]]
}

# What a session is built from where nothing rendered /etc/nixcage: the layer
# this nixcage was built with, named across sudo because sudo clears the
# environment (ADR-023).
@test "enter with no host config runs the layer this nixcage was built with" {
	mkdir -p "$TEST_TEMP_DIR/proj"
	cd "$TEST_TEMP_DIR/proj"
	run_nixcage enter
	[ "$status" -eq 0 ]
	local called
	called="$(cat "$TEST_TEMP_DIR/sudo-calls")"
	[[ "$called" == "$NIXCAGE_CONTAINER enter"* ]]
	[[ "$called" == *"--profile $NIXCAGE_PROFILE"* ]]
}

@test "enter with no host config and no layer says where one comes from" {
	unset NIXCAGE_CONTAINER NIXCAGE_PROFILE
	mkdir -p "$TEST_TEMP_DIR/proj"
	cd "$TEST_TEMP_DIR/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *"nix run github:hamidr/nixcage"* ]]
}
