#!/usr/bin/env bats
# On Linux the CLI drives host-native containers: local exec, host config,
# no VM lifecycle commands.

load ../test_helper/common

setup() {
	setup_temp_dir
	# Force the Linux code path regardless of the machine running the tests.
	export NIXCAGE_OS=linux
	# Host config normally rendered to /etc/nixcage/config by nixosModules.host.
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/host-config"
	# Stub sudo and nixcage-container so 'enter' can be observed without root.
	mkdir -p "$TEST_TEMP_DIR/bin"
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

write_host_config() {
	echo "WORKSPACE_ROOTS=${1:-$TEST_TEMP_DIR/src}" >"$NIXCAGE_HOST_CONFIG"
}

@test "rebuild on linux fails pointing at nixos-rebuild" {
	run_nixcage rebuild
	[ "$status" -ne 0 ]
	[[ "$output" == *nixos-rebuild* ]]
}

@test "down on linux fails pointing at nixos-rebuild" {
	run_nixcage down
	[ "$status" -ne 0 ]
	[[ "$output" == *nixos-rebuild* ]]
}

@test "enter without the host config fails pointing at nixosModules.host" {
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *nixosModules.host* ]]
}

@test "enter outside every workspace root fails using host config roots" {
	write_host_config "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/elsewhere/proj"
	touch "$TEST_TEMP_DIR/elsewhere/proj/flake.nix"
	cd "$TEST_TEMP_DIR/elsewhere/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

@test "enter runs nixcage-container locally via sudo with name and path" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == nixcage-container\ enter\ proj-*\ "$TEST_TEMP_DIR/src/proj"\ true ]]
}

@test "rm on linux removes the container locally" {
	write_host_config
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	run bash -c "echo y | NIXCAGE_OS=linux NIXCAGE_HOST_CONFIG='$NIXCAGE_HOST_CONFIG' PATH='$PATH' bash '$NIXCAGE_BIN' rm somename"
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == *"nixcage-container rm somename"* ]]
}

@test "status on linux lists containers without VM fields" {
	write_host_config
	run_nixcage status
	[ "$status" -eq 0 ]
	[[ "$output" == *Containers:* ]]
	[[ "$output" != *"Built:"* ]]
	[[ "$output" != *"SSH port:"* ]]
}
