#!/usr/bin/env bats
# On Linux the CLI drives host-native containers: local exec, host config,
# no VM lifecycle commands.

load ../test_helper/common

setup() {
	setup_temp_dir
	# Force the Linux code path regardless of the machine running the tests.
	export NIXCAGE_OS=linux
	# Host config normally rendered to /etc/nixcage/config by nixosModules.host.
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/declaration"
	# Never the machine's own: these tests run on a developer's host.
	export NIXCAGE_LEGACY_HOST_CONFIG="$TEST_TEMP_DIR/legacy-config"
	export NIXCAGE_LEGACY_CONTAINER_CONFIG="$TEST_TEMP_DIR/legacy-container"
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

# What nixosModules.host renders: one versioned declaration.
write_host_config() {
	cat >"$NIXCAGE_HOST_CONFIG" <<-EOF
		DECLARATION_VERSION=1
		HOST_PLATFORM=linux
		WORKSPACE_ROOTS=${1:-$TEST_TEMP_DIR/src}
	EOF
}

# What a nixcage before the declaration rendered, which a CLI newer than the
# module it stands on still has to read.
write_legacy_host_config() {
	echo "WORKSPACE_ROOTS=${1:-$TEST_TEMP_DIR/src}" >"$NIXCAGE_LEGACY_HOST_CONFIG"
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

@test "enter --substrate hands the word to nixcage-container, which owns the choice" {
	# The CLI knows nothing of substrates beyond the flag (ADR-019): what
	# the cage's record or the host's declaration say is read there.
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --substrate microvm -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == nixcage-container\ enter\ --substrate\ microvm\ proj-*\ "$TEST_TEMP_DIR/src/proj"\ true ]]
}

@test "enter --disk hands the size through beside the substrate, in either order" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --disk 2G --substrate microvm -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == nixcage-container\ enter\ --disk\ 2G\ --substrate\ microvm\ proj-*\ "$TEST_TEMP_DIR/src/proj"\ true ]]
	run_nixcage enter --disk big
	[ "$status" -ne 0 ]
	[[ "$output" == *"--disk needs a size"* ]]
}

# Written as --flag=value by two people in one issue before anyone noticed:
# the word-only match let the whole flag fall through to the command, so the
# session ran it inside a cage on the substrate it was trying to change.
@test "enter --substrate=word is the same flag, not a command to run" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --substrate=microvm -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == nixcage-container\ enter\ --substrate\ microvm\ proj-*\ "$TEST_TEMP_DIR/src/proj"\ true ]]
}

@test "enter --disk=size is the same flag, not a command to run" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --disk=2G --substrate=microvm -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == nixcage-container\ enter\ --disk\ 2G\ --substrate\ microvm\ proj-*\ "$TEST_TEMP_DIR/src/proj"\ true ]]
}

@test "enter --substrate=nonsense is refused, as the spaced form is" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --substrate=qemu
	[ "$status" -ne 0 ]
	[[ "$output" == *"--substrate needs nspawn or microvm"* ]]
}

@test "enter --substrate without a word is refused" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter --substrate
	[ "$status" -ne 0 ]
	[[ "$output" == *"--substrate needs nspawn or microvm"* ]]
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

@test "enter forwards the ssh agent socket when one is available" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	# A plain file stands in for the socket: the CLI only checks it exists.
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" == *"--auth-sock $TEST_TEMP_DIR/agent.sock"* ]]
}

@test "enter omits the agent socket when no agent is running" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" != *--auth-sock* ]]
}

@test "enter omits the agent socket when SSH_AUTH_SOCK points nowhere" {
	write_host_config
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	touch "$TEST_TEMP_DIR/src/proj/flake.nix"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/gone.sock"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	[[ "$output" != *--auth-sock* ]]
}

# A declared host rendered the layer and the symlink to it, so the session is
# given neither: what it reads is what its administrator applied (ADR-023).
@test "enter on a declared host names no profile and runs the host's own container" {
	export NIXCAGE_CONTAINER=/nix/store/aaa-nixcage-container/bin/nixcage-container
	write_host_config "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -eq 0 ]
	local called
	called="$(cat "$TEST_TEMP_DIR/sudo-calls")"
	[[ "$called" == "nixcage-container enter"* ]]
	[[ "$called" != *--profile* ]]
}


# A declared host rendered its identity from nixcage.git.*, so the session is
# given none: reading the invoking user's git would contradict what its
# administrator applied (ADR-023 decision 11).
@test "enter on a declared host names no identity" {
	write_host_config "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" != *--git-name* ]]
}


@test "status on a declared host reads its config and says nothing about undeclared mode" {
	write_host_config "$TEST_TEMP_DIR/src"
	run_nixcage status
	[ "$status" -eq 0 ]
	[[ "$output" == *"$TEST_TEMP_DIR/src"* ]]
	[[ "$output" != *"nothing declared"* ]]
}


# A declared host has nixcage-container on its path, installed by the module,
# and exec hands over what it was given (ADR-009).
@test "exec on a declared host passes the name through untouched" {
	write_host_config "$TEST_TEMP_DIR/src"
	export NIXCAGE_CONTAINER=/nix/store/aaa-nixcage-container/bin/nixcage-container
	run_nixcage exec -- nixcage-container list
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == "nixcage-container list" ]]
}

# A CLI newer than the module it stands on (ADR-024 decision 7). Removed one
# release after the declaration lands.
@test "a declaration an older nixcage rendered is read, and said to be old" {
	write_legacy_host_config "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -eq 0 ]
	[[ "$output" == *"older nixcage"* ]]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == "nixcage-container enter"* ]]
}

@test "a declaration an older nixcage rendered still gates on its roots" {
	write_legacy_host_config "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/elsewhere/proj"
	cd "$TEST_TEMP_DIR/elsewhere/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

# A host that declared roots must never read as a host that declared nothing,
# which is what a version-blind reader would do the first time the format
# changes (ADR-024 decision 6).
@test "a declaration from a newer nixcage stops the session" {
	printf 'DECLARATION_VERSION=99\nWORKSPACE_ROOTS=%s\n' "$TEST_TEMP_DIR/src" \
		>"$NIXCAGE_HOST_CONFIG"
	mkdir -p "$TEST_TEMP_DIR/src/proj"
	cd "$TEST_TEMP_DIR/src/proj"
	run_nixcage enter
	[ "$status" -ne 0 ]
	[[ "$output" == *99* ]]
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}
