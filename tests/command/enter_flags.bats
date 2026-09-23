#!/usr/bin/env bats
# What the CLI does with the options a session takes. The CLI is a person's
# tool and nixcage-container is a program's (ADR-009), so the flags a person
# uses reach the session and the ones that parameterise a session on a
# dependant's behalf are refused by name, pointing at exec. Nothing is passed
# through as the command by accident.

load ../test_helper/common

setup() {
	setup_temp_dir
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/host-config"
	echo "WORKSPACE_ROOTS=$TEST_TEMP_DIR" >"$NIXCAGE_HOST_CONFIG"
	mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/proj"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/sudo-calls"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/sudo"
	cd "$TEST_TEMP_DIR/proj"
}

teardown() {
	teardown_temp_dir
}

called() { cat "$TEST_TEMP_DIR/sudo-calls"; }

# A flag reaches the session only if it stands before the cage's name: after
# it, the same words are the command the session runs, which is exactly the
# confusion this file exists to prevent.
asked() {
	local line
	line="$(called)"
	[[ "${line%% proj-*}" == *"$1"* ]]
}

@test "a bound reaches the session instead of becoming its command" {
	run_nixcage enter --memory 8G --cpus 4
	[ "$status" -eq 0 ]
	asked "--memory 8G"
	asked "--cpus 4"
}

@test "a joined spelling is the flag it is spelt like" {
	run_nixcage enter --memory=8G
	[ "$status" -eq 0 ]
	asked "--memory 8G"
}

@test "a bind and an environment variable reach the session" {
	run_nixcage enter --bind /srv/data:/data --bind-ro /etc/hosts:/etc/hosts --setenv K=V
	[ "$status" -eq 0 ]
	asked "--bind /srv/data:/data"
	asked "--bind-ro /etc/hosts:/etc/hosts"
	asked "--setenv K=V"
}

@test "the flags that take no value reach the session" {
	run_nixcage enter --no-agent --print-argv
	[ "$status" -eq 0 ]
	asked --no-agent
	asked --print-argv
}

@test "a named devShell reaches the session" {
	run_nixcage enter --shell ci
	[ "$status" -eq 0 ]
	asked "--shell ci"
}

@test "the command still follows the flags" {
	run_nixcage enter --memory 8G -- claude --dangerously
	[ "$status" -eq 0 ]
	[[ "$(called)" == *"$TEST_TEMP_DIR/proj claude --dangerously" ]]
}

# These parameterise a session on behalf of a dependant, which is what exec
# carries a caller to (ADR-009). Refused by name rather than run as a command.
@test "a flag that belongs to a dependant is refused, naming exec" {
	for flag in --uid --user --subject --home --network --dns --store-root --profile --guest; do
		run_nixcage enter "$flag" x
		[ "$status" -ne 0 ]
		[[ "$output" == *"$flag"* ]]
		[[ "$output" == *"nixcage exec"* ]]
	done
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}

@test "a flag nixcage does not have is refused rather than run" {
	run_nixcage enter --nope
	[ "$status" -ne 0 ]
	[[ "$output" == *--nope* ]]
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}

@test "a flag with no value is refused rather than swallowing the command" {
	run_nixcage enter --memory
	[ "$status" -ne 0 ]
	[[ "$output" == *--memory* ]]
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}

@test "the substrate and the disk keep the words they always took" {
	run_nixcage enter --substrate microvm --disk 2G
	[ "$status" -eq 0 ]
	asked "--substrate microvm"
	asked "--disk 2G"
}

@test "a substrate nixcage cannot run is refused before anything starts" {
	run_nixcage enter --substrate lxc
	[ "$status" -ne 0 ]
	[[ "$output" == *nspawn* ]]
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}
