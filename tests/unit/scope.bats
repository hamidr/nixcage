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
	export NIXCAGE_STATE_DIR="$TEST_TEMP_DIR/var"
	CALLS="$TEST_TEMP_DIR/systemctl.calls"
	mkdir -p "$TEST_TEMP_DIR/bin"
	cat >"$TEST_TEMP_DIR/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
case "\$*" in
*"show -p ActiveState --value machine-builder.scope"*) echo active ;;
*"show -p ActiveState --value bare.scope"*) echo active ;;
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
	local name="$1" nspawn="$2" leader="$3" unit="${4:-machine-$1.scope}"
	mkdir -p "$NIXCAGE_CGROUP_ROOT/machine.slice/$unit"
	printf '%s\n%s\n' "$nspawn" "$leader" >"$NIXCAGE_CGROUP_ROOT/machine.slice/$unit/cgroup.procs"
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

@test "a microvm cage's scope is found under the spelling vmspawn escapes, dashes as \\x2d" {
	# nspawn registers the name as it is; vmspawn escapes it as a unit
	# name, so a cage with a dash, which every derived name has, lives
	# under machine-a\x2db.scope.
	mkdir -p "$NIXCAGE_CGROUP_ROOT/machine.slice/machine-builder\\x2dhand.scope" "$NIXCAGE_PROC/5000" "$NIXCAGE_PROC/5001"
	printf '5001\n' >"$NIXCAGE_CGROUP_ROOT/machine.slice/machine-builder\\x2dhand.scope/cgroup.procs"
	printf 'Name:\tsystemd-vmspawn\nPPid:\t1\n' >"$NIXCAGE_PROC/5000/status"
	printf 'Name:\tqemu-kvm\nPPid:\t5000\n' >"$NIXCAGE_PROC/5001/status"
	cat >"$TEST_TEMP_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*"machine-builder\\x2dhand.scope"*) echo active ;;
*) echo inactive ;;
esac
STUB
	chmod +x "$TEST_TEMP_DIR/bin/systemctl"
	run nixcage_scope_unit builder-hand
	assert_output 'machine-builder\x2dhand.scope'
	run nixcage_scope_status builder-hand
	assert_output 'running 5001 machine.slice/machine-builder\x2dhand.scope'
}

@test "a running microvm cage's leader is qemu, the process whose parent is vmspawn" {
	# vmspawn registers the scope as nspawn does and stays outside it; the
	# VM is one process in it, and status, stop and list read it the same.
	mkdir -p "$NIXCAGE_CGROUP_ROOT/machine.slice/machine-builder.scope" "$NIXCAGE_PROC/5000" "$NIXCAGE_PROC/5001"
	printf '5001\n' >"$NIXCAGE_CGROUP_ROOT/machine.slice/machine-builder.scope/cgroup.procs"
	printf 'Name:\tsystemd-vmspawn\nPPid:\t1\n' >"$NIXCAGE_PROC/5000/status"
	printf 'Name:\tqemu-kvm\nPPid:\t5000\n' >"$NIXCAGE_PROC/5001/status"
	run nixcage_scope_leader builder
	assert_success
	assert_output "5001"
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

@test "netns of a running microvm cage is none: a VM has no namespace on the host" {
	# The leader is qemu, whose namespace is the host's own; handing that
	# out would put a second cage in the host's network (ADR-019).
	running_cage builder 4000 4001
	nixcage_scope_record_write builder 700000 "" "" "" "" microvm
	run nixcage_scope_netns builder
	assert_success
	assert_output none
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

# systemd 261's nspawn, told --register=no, names the scope <name>.scope
# rather than machine-<name>.scope; a machine whose cages all ran answered
# stopped for every one, and enter started a second cage into the first's
# unit: "Failed to allocate scope: Unit backend.scope was already loaded".
@test "a cage whose scope nspawn named without the machine- prefix is running, with that cgroup" {
	running_cage bare 5000 5001 bare.scope
	run nixcage_scope_status bare
	assert_success
	assert_output "running 5001 machine.slice/bare.scope"
}

# systemd 261's nspawn also keeps itself outside the scope and puts the
# cage under <scope>/payload/, so the scope's own cgroup.procs is empty and
# nspawn is not in it at all; the leader is then the payload's first
# process whose parent is nspawn, wherever nspawn sits.
@test "a cage whose processes nspawn put under payload/ is running, and its leader is read from there" {
	running_cage bare 5000 5001 bare.scope
	rm "$NIXCAGE_CGROUP_ROOT/machine.slice/bare.scope/cgroup.procs"
	mkdir -p "$NIXCAGE_CGROUP_ROOT/machine.slice/bare.scope/payload"
	: >"$NIXCAGE_CGROUP_ROOT/machine.slice/bare.scope/cgroup.procs"
	printf '%s\n' 5001 >"$NIXCAGE_CGROUP_ROOT/machine.slice/bare.scope/payload/cgroup.procs"
	run nixcage_scope_status bare
	assert_success
	assert_output "running 5001 machine.slice/bare.scope"
}

@test "stop stops whichever spelling of the scope is active" {
	running_cage bare 5000 5001 bare.scope
	run nixcage_scope_stop bare
	assert_success
	run cat "$CALLS"
	assert_line "stop bare.scope"
}

@test "a name outside the cage alphabet is refused before it reaches a unit name" {
	run nixcage_scope_status "../etc"
	assert_failure
	[ ! -e "$CALLS" ]
}

# What each cage was given, recorded at enter and read back by list --json
# (ADR-017). The dependant kept a table of its own for every one of these
# facts, which nixcage had at enter and threw away.

@test "enter's record holds what it was given, as one JSON object under the cage's state directory" {
	nixcage_scope_record_write builder 700000 agent fabriek0 10.77.0.10/24 "" "" /nix/store/aaaa-profile /nix/store/bbbb-tool
	local record="$NIXCAGE_STATE_DIR/containers/builder/placement"
	[ -f "$record" ]
	[ "$(wc -l <"$record")" -eq 1 ]
	[ "$(jq -r .name "$record")" = builder ]
	[ "$(jq .uid "$record")" = 700000 ]
	[ "$(jq -r .subject "$record")" = agent ]
	[ "$(jq -r .bridge "$record")" = fabriek0 ]
	[ "$(jq -r .address "$record")" = 10.77.0.10/24 ]
	[ "$(jq -c .roots "$record")" = '["/nix/store/aaaa-profile","/nix/store/bbbb-tool"]' ]
	[ "$(jq 'has("netns")' "$record")" = false ]
}

@test "a record for an ordinary session names the cage and its uid and nothing it was not given" {
	nixcage_scope_record_write builder 700000 "" "" "" "" ""
	run jq -c 'keys' "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output '["name","uid"]'
}

@test "a microvm session records its substrate, and the record answers for it afterwards" {
	# The choice is fixed at the first enter (ADR-019); the next enter of
	# the name reads it here before it reads its own flag.
	nixcage_scope_record_write builder 700000 "" "" "" "" microvm
	run jq -r .substrate "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output microvm
	run nixcage_scope_record_substrate builder
	assert_output microvm
}

@test "an nspawn session records no substrate: absent is what every cage was before ADR-019" {
	nixcage_scope_record_write builder 700000 "" "" "" "" nspawn
	[ "$(jq 'has("substrate")' "$NIXCAGE_STATE_DIR/containers/builder/placement")" = false ]
	run nixcage_scope_record_substrate builder
	assert_success
	assert_output ""
	run nixcage_scope_record_substrate never-entered
	assert_success
	assert_output ""
}

@test "a session joining a running cage's namespace records that path, since it has no address of its own" {
	nixcage_scope_record_write builder-hand 700000 "" "" "" /proc/4001/ns/net ""
	run jq -r .netns "$NIXCAGE_STATE_DIR/containers/builder-hand/placement"
	assert_output /proc/4001/ns/net
}

@test "the next enter under the name overwrites the record" {
	nixcage_scope_record_write builder 700000 agent fabriek0 10.77.0.10/24 "" ""
	nixcage_scope_record_write builder 700000 "" "" "" "" ""
	run jq -c 'keys' "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output '["name","uid"]'
}

@test "list --json shows a running cage with a record with every field, its scope and its leader" {
	running_cage builder 4000 4001
	nixcage_scope_record_write builder 700000 agent fabriek0 10.77.0.10/24 "" "" /nix/store/aaaa-profile
	run nixcage_scope_list_json
	assert_success
	[ "$(jq -r .name <<<"$output")" = builder ]
	[ "$(jq .uid <<<"$output")" = 700000 ]
	[ "$(jq -r .subject <<<"$output")" = agent ]
	[ "$(jq -r .bridge <<<"$output")" = fabriek0 ]
	[ "$(jq -r .address <<<"$output")" = 10.77.0.10/24 ]
	[ "$(jq -c .roots <<<"$output")" = '["/nix/store/aaaa-profile"]' ]
	[ "$(jq -r .scope <<<"$output")" = machine.slice/machine-builder.scope ]
	[ "$(jq .leader <<<"$output")" = 4001 ]
}

@test "a stopped cage with a record lists without scope and leader" {
	nixcage_scope_record_write reviewer 700010 "" fabriek0 10.77.0.11/24 "" ""
	run nixcage_scope_list_json
	assert_success
	[ "$(jq -r .name <<<"$output")" = reviewer ]
	[ "$(jq -r .address <<<"$output")" = 10.77.0.11/24 ]
	[ "$(jq 'has("scope")' <<<"$output")" = false ]
	[ "$(jq 'has("leader")' <<<"$output")" = false ]
}

@test "a cage without a record, entered before records were kept, lists with its name and its scope alone" {
	mkdir -p "$NIXCAGE_STATE_DIR/containers/bare"
	running_cage bare 5000 5001 bare.scope
	run nixcage_scope_list_json
	assert_success
	run jq -c 'keys' <<<"$output"
	assert_output '["leader","name","scope"]'
}

@test "the output is one object per line, one per name in order, each parseable by jq -c" {
	running_cage builder 4000 4001
	nixcage_scope_record_write builder 700000 "" fabriek0 10.77.0.10/24 "" ""
	nixcage_scope_record_write reviewer 700010 "" fabriek0 10.77.0.11/24 "" ""
	mkdir -p "$NIXCAGE_STATE_DIR/containers/bare"
	run nixcage_scope_list_json
	assert_success
	[ "${#lines[@]}" -eq 3 ]
	local line
	for line in "${lines[@]}"; do
		jq -c . <<<"$line" >/dev/null
	done
	[ "$(jq -r .name <<<"${lines[0]}")" = bare ]
	[ "$(jq -r .name <<<"${lines[1]}")" = builder ]
	[ "$(jq -r .name <<<"${lines[2]}")" = reviewer ]
}

@test "list --json with no cage ever entered prints nothing and succeeds" {
	run nixcage_scope_list_json
	assert_success
	assert_output ""
}

# A session entered with --home has its home where the caller said, not
# under the state directory, and exec on a microvm cage reads the session's
# group from it (ADR-019 decision 6); found 2026-09-22 on a cage whose home
# was a dependant's: "has no home". The record carries the home when one
# was asked, and a record without one reads as the default.

@test "the record carries the home a session was given, among what else it was given" {
	nixcage_scope_record_write builder 700000 agent fabriek0 10.77.0.10/24 "" microvm --home=/srv/homes/builder /nix/store/aaaa-profile
	run cat "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output '{"name":"builder","uid":700000,"subject":"agent","bridge":"fabriek0","address":"10.77.0.10/24","substrate":"microvm","home":"/srv/homes/builder","roots":["/nix/store/aaaa-profile"]}'
	run nixcage_scope_record_home builder
	assert_output "/srv/homes/builder"
}

@test "a record without a home says nothing, so the caller falls back to the default" {
	nixcage_scope_record_write builder 700000 "" "" "" "" ""
	run nixcage_scope_record_home builder
	assert_success
	assert_output ""
}


# Which nixcage wrote a record, and whether that session had a declaration to
# read (ADR-023 decision 4). A machine can hold cages written by a nixcage
# from the store and cages written by one a module installed, so a format that
# diverges later is a message rather than a puzzle.

@test "a record names the nixcage that wrote it and says it was undeclared" {
	nixcage_scope_record_write builder 700000 "" "" "" "" "" \
		--writer=/nix/store/aaa-nixcage-container/bin/nixcage-container --declared=
	local record="$NIXCAGE_STATE_DIR/containers/builder/placement"
	[ "$(jq -r .writer "$record")" = /nix/store/aaa-nixcage-container/bin/nixcage-container ]
	[ "$(jq -r .declared "$record")" = false ]
}

@test "a record of a declared session says so" {
	nixcage_scope_record_write builder 700000 "" "" "" "" "" \
		--writer=/nix/store/aaa-nixcage-container/bin/nixcage-container --declared=1
	[ "$(jq -r .declared "$NIXCAGE_STATE_DIR/containers/builder/placement")" = true ]
}

# Absent is what every record held before this, so one written by an older
# nixcage still reads.
@test "a record written without a writer keeps the shape it always had" {
	nixcage_scope_record_write builder 700000 "" "" "" "" ""
	run jq -c 'keys' "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output '["name","uid"]'
}


# A session may carry mounts its caller never named (ADR-025), so the record
# says which: what the host declared for this cage is distinguishable there
# from what the session asked for.

@test "a record names the binds the host declared for the cage" {
	nixcage_scope_record_write builder 700000 "" "" "" "" "" \
		"--declared-bind=--bind-ro=/srv/models:/models" \
		"--declared-bind=--bind=/data:/data"
	local record="$NIXCAGE_STATE_DIR/containers/builder/placement"
	[ "$(jq -c .declaredBinds "$record")" = '["--bind-ro=/srv/models:/models","--bind=/data:/data"]' ]
}

@test "a cage nothing was declared for keeps the record it always had" {
	nixcage_scope_record_write builder 700000 "" "" "" "" ""
	run jq -c 'keys' "$NIXCAGE_STATE_DIR/containers/builder/placement"
	assert_output '["name","uid"]'
}
