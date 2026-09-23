#!/usr/bin/env bats
# What cages this machine has, and what each was given (ADR-017). The record
# already held it and only the container script could show it; this is the
# verb a person uses.

load ../test_helper/common

setup() {
	setup_temp_dir
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/declaration"
	export NIXCAGE_LEGACY_HOST_CONFIG="$TEST_TEMP_DIR/legacy-config"
	export NIXCAGE_LEGACY_CONTAINER_CONFIG="$TEST_TEMP_DIR/legacy-container"
	printf 'DECLARATION_VERSION=1\nWORKSPACE_ROOTS=%s\n' "$TEST_TEMP_DIR" \
		>"$NIXCAGE_HOST_CONFIG"
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	# One record per line, as the container script prints them.
	cat >"$TEST_TEMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$TEST_TEMP_CALLS"
cat "$TEST_TEMP_RECORDS"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/sudo"
	export TEST_TEMP_CALLS="$TEST_TEMP_DIR/sudo-calls"
	export TEST_TEMP_RECORDS="$TEST_TEMP_DIR/records"
	cat >"$TEST_TEMP_RECORDS" <<'EOF'
{"name":"proj-1234abcd","uid":700000,"substrate":"microvm","declared":true,"scope":"/machine.slice/proj.scope","leader":4001}
{"name":"other-5678efgh","uid":1000,"declared":false,"declaredBinds":["--bind-ro=/srv/models:/models"]}
EOF
}

teardown() {
	teardown_temp_dir
}

@test "list asks the container script for the records" {
	run_nixcage list
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_CALLS")" == "nixcage-container list --json" ]]
}

@test "list names each cage, its substrate and whether it is running" {
	run_nixcage list
	[ "$status" -eq 0 ]
	[[ "$output" == *proj-1234abcd* ]]
	[[ "$output" == *microvm* ]]
	[[ "$output" == *running* ]]
	[[ "$output" == *other-5678efgh* ]]
	[[ "$output" == *stopped* ]]
}

# Absent is what every record held before ADR-019, so a cage with no
# substrate in its record is the one every cage used to be.
@test "a cage whose record names no substrate is an nspawn cage" {
	run_nixcage list
	[[ "$output" == *nspawn* ]]
}

@test "list names the uid a cage is mapped onto" {
	run_nixcage list
	[[ "$output" == *700000* ]]
}

@test "list --json hands the records over as they are" {
	run_nixcage list --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .name <<<"${lines[0]}")" = proj-1234abcd ]
	[ "$(jq -c .declaredBinds <<<"${lines[1]}")" = '["--bind-ro=/srv/models:/models"]' ]
}

@test "a machine with no cages says so rather than printing a bare header" {
	: >"$TEST_TEMP_RECORDS"
	run_nixcage list
	[ "$status" -eq 0 ]
	[[ "$output" == *"No cages"* ]]
}

@test "list on a host that declared nothing reaches the layer the CLI carries" {
	rm "$NIXCAGE_HOST_CONFIG"
	export NIXCAGE_CONTAINER=/nix/store/aaa-nixcage-container/bin/nixcage-container
	run_nixcage list
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_CALLS")" == "$NIXCAGE_CONTAINER list --json" ]]
}


# Listing is a question, not an instruction: asking what cages exist must not
# start a virtual machine to answer.
@test "list on macos does not boot the VM to answer" {
	unset NIXCAGE_OS
	export NIXCAGE_OS=macos
	write_cache 22022 "$TEST_TEMP_DIR/src"
	run_nixcage list
	[ "$status" -ne 0 ]
	[[ "$output" == *"not running"* ]]
	[ ! -f "$TEST_TEMP_CALLS" ]
}

@test "list --json on macos with no VM says nothing rather than an empty set" {
	unset NIXCAGE_OS
	export NIXCAGE_OS=macos
	write_cache 22022 "$TEST_TEMP_DIR/src"
	run_nixcage list --json
	[ "$status" -ne 0 ]
	[ -z "${lines[0]:-}" ] || [[ "${lines[0]}" != "{"* ]]
}


# A row is four fields because the query gives four; the columns still do not
# assume it, because a record nixcage did not write is a record nixcage did
# not check.
@test "a record with fields missing is printed rather than crashing the verb" {
	printf '{"name":""}\n{"name":"real-1234abcd","uid":7}\n' >"$TEST_TEMP_RECORDS"
	run_nixcage list
	[ "$status" -eq 0 ]
	[[ "$output" == *real-1234abcd* ]]
}
