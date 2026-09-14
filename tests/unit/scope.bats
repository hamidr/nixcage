#!/usr/bin/env bats
# A cage has a scope, and nixcage answers for it (ADR-012): the verbs over a
# running cage, driven on a fixture cgroup tree and proc tree with systemctl
# stubbed, so what they read and what they run is asserted without a cage.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/scope.sh
	source "$NIXCAGE_ROOT/modules/scope.sh"
	export NIXCAGE_CGROUP_ROOT="$TEST_TEMP_DIR/cgroup"
	export NIXCAGE_PROC="$TEST_TEMP_DIR/proc"
	CALLS="$TEST_TEMP_DIR/systemctl.calls"
	mkdir -p "$TEST_TEMP_DIR/bin"
	cat >"$TEST_TEMP_DIR/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
case "\$*" in
*"show -p ActiveState --value machine-builder.scope"*) echo active ;;
*"show -p ActiveState --value "*) echo inactive ;;
esac
STUB
	chmod +x "$TEST_TEMP_DIR/bin/systemctl"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
	teardown_temp_dir
}

## A running cage as the kernel shows it: nspawn and its payload in one
## cgroup, each pid with a status file naming its parent.
running_cage() {
	local name="$1" nspawn="$2" leader="$3"
	mkdir -p "$NIXCAGE_CGROUP_ROOT/machine.slice/machine-$name.scope"
	printf '%s\n%s\n' "$nspawn" "$leader" >"$NIXCAGE_CGROUP_ROOT/machine.slice/machine-$name.scope/cgroup.procs"
	mkdir -p "$NIXCAGE_PROC/$nspawn" "$NIXCAGE_PROC/$leader"
	printf 'Name:\tsystemd-nspawn\nPPid:\t1\n' >"$NIXCAGE_PROC/$nspawn/status"
	printf 'Name:\tbash\nPPid:\t%s\n' "$nspawn" >"$NIXCAGE_PROC/$leader/status"
}

@test "a cage's scope and cgroup are named after it, under machine.slice" {
	run nixcage_scope_unit builder
	assert_output "machine-builder.scope"
	run nixcage_scope_cgroup builder
	assert_output "machine.slice/machine-builder.scope"
}

@test "a running cage's leader is the process whose parent is nspawn, not nspawn itself" {
	running_cage builder 4000 4001
	run nixcage_scope_leader builder
	assert_success
	assert_output "4001"
}

@test "status says running with the leader and the cgroup, from the scope" {
	running_cage builder 4000 4001
	run nixcage_scope_status builder
	assert_success
	assert_output "running 4001 machine.slice/machine-builder.scope"
	run grep -c "show -p ActiveState --value machine-builder.scope" "$CALLS"
	assert_output 1
}

@test "status says stopped for a cage whose scope is not active, and reads no cgroup" {
	run nixcage_scope_status reviewer
	assert_success
	assert_output "stopped"
}

@test "netns is the leader's namespace path, the one enter --network ns: takes" {
	running_cage builder 4000 4001
	run nixcage_scope_netns builder
	assert_success
	assert_output "$NIXCAGE_PROC/4001/ns/net"
}

@test "netns of a cage that is not running fails naming the cage" {
	run nixcage_scope_netns reviewer
	assert_failure
	assert_output --partial "reviewer is not running"
}

@test "stop stops the scope and nothing else" {
	running_cage builder 4000 4001
	run nixcage_scope_stop builder
	assert_success
	run cat "$CALLS"
	assert_line "stop machine-builder.scope"
}

@test "a name outside the cage alphabet is refused before it reaches a unit name" {
	run nixcage_scope_status "../etc"
	assert_failure
	[ ! -e "$CALLS" ]
}
