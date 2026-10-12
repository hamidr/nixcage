#!/usr/bin/env bats
# rm resolves its target and asks before deleting

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "rm without a name outside every workspace root fails" {
	write_cache 22022 "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/elsewhere/proj"
	cd "$TEST_TEMP_DIR/elsewhere/proj"
	run_nixcage rm
	[ "$status" -ne 0 ]
	[[ "$output" == *workspaceRoots* ]]
}

# A directory under a workspace root is a project whether or not it declares a
# flake (ADR-021), so the cage it was entered with is removable from it.
@test "rm without a name in a directory with no flake.nix resolves the cage" {
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache 22022 "$TEST_TEMP_DIR/src"
	mkdir -p "$TEST_TEMP_DIR/src/noflake"
	cd "$TEST_TEMP_DIR/src/noflake"
	run bash -c "echo n | bash '$NIXCAGE_BIN' rm"
	[ "$status" -eq 0 ]
	[[ "$output" == *noflake* ]]
	[[ "$output" == *Aborted* ]]
}

@test "rm answering no aborts without touching the VM" {
	# A running-VM marker with our own PID makes vm_is_running true, so rm
	# reaches the confirmation prompt without booting anything.
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache
	run bash -c "echo n | bash '$NIXCAGE_BIN' rm somename"
	[ "$status" -eq 0 ]
	[[ "$output" == *Aborted* ]]
}

# A script has no one to answer the prompt: --yes is the answer given ahead,
# and a closed stdin is refused by name rather than ending the run silently.

@test "rm --yes deletes without asking" {
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache
	mkdir -p "$TEST_TEMP_DIR/bin"
	printf '#!/usr/bin/env bash\necho "$@" >>"%s/ssh-calls"\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/ssh"
	printf '#!/usr/bin/env bash\necho microvm-run\n' >"$TEST_TEMP_DIR/bin/ps"
	chmod +x "$TEST_TEMP_DIR/bin/ssh" "$TEST_TEMP_DIR/bin/ps"
	PATH="$TEST_TEMP_DIR/bin:$PATH" run bash "$NIXCAGE_BIN" rm --yes somename </dev/null
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/ssh-calls")" == *"nixcage-container rm somename"* ]]
}

@test "rm with nothing on stdin to answer refuses, naming --yes" {
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache
	run bash "$NIXCAGE_BIN" rm somename </dev/null
	[ "$status" -ne 0 ]
	[[ "$output" == *--yes* ]]
}
