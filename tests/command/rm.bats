#!/usr/bin/env bats
# rm resolves its target and asks before deleting

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "rm without a name outside a project fails with usage" {
	mkdir -p "$TEST_TEMP_DIR/noflake"
	cd "$TEST_TEMP_DIR/noflake"
	run_nixcage rm
	[ "$status" -ne 0 ]
	[[ "$output" == *Usage:* ]]
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
