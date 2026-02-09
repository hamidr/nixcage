#!/usr/bin/env bats
# Tests for resource limits configuration (Spec §4.2 sandbox.resources)

setup() {
	load '../test_helper/common'
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "resources: cpus=0 and memory='' are defaults (no limits)" {
	create_test_config "$TEST_TEMP_DIR"
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_CPUS" "0"
	assert_equal "$CAGE_MEMORY" ""
}

@test "resources: cpus and memory are parsed correctly" {
	cat >"$TEST_TEMP_DIR/nixcage.toml" <<'TOML'
[sandbox.resources]
cpus = 4
memory = "8G"
TOML
	parse_config "$TEST_TEMP_DIR/nixcage.toml"
	assert_equal "$CAGE_CPUS" "4"
	assert_equal "$CAGE_MEMORY" "8G"
}

@test "resources: systemd-run prefix is constructed correctly" {
	CAGE_CPUS="2"
	CAGE_MEMORY="4G"

	# Simulate the prefix construction from run_linux
	local prefix=()
	if [[ "$CAGE_CPUS" != "0" || -n "$CAGE_MEMORY" ]]; then
		prefix=(systemd-run --user --scope -q)
		[[ "$CAGE_CPUS" != "0" ]] && prefix+=(-p "CPUQuota=${CAGE_CPUS}00%")
		[[ -n "$CAGE_MEMORY" ]] && prefix+=(-p "MemoryMax=$CAGE_MEMORY")
	fi

	local joined="${prefix[*]}"
	[[ "$joined" == *"systemd-run --user --scope -q"* ]]
	[[ "$joined" == *"CPUQuota=200%"* ]]
	[[ "$joined" == *"MemoryMax=4G"* ]]
}

@test "resources: no systemd-run prefix when both are default" {
	CAGE_CPUS="0"
	CAGE_MEMORY=""

	local prefix=()
	if [[ ("$CAGE_CPUS" != "0" || -n "$CAGE_MEMORY") ]]; then
		prefix=(systemd-run --user --scope -q)
	fi

	assert_equal "${#prefix[@]}" "0"
}

@test "resources: only cpus non-default adds CPUQuota" {
	CAGE_CPUS="8"
	CAGE_MEMORY=""

	local prefix=()
	if [[ "$CAGE_CPUS" != "0" || -n "$CAGE_MEMORY" ]]; then
		prefix=(systemd-run --user --scope -q)
		[[ "$CAGE_CPUS" != "0" ]] && prefix+=(-p "CPUQuota=${CAGE_CPUS}00%")
		[[ -n "$CAGE_MEMORY" ]] && prefix+=(-p "MemoryMax=$CAGE_MEMORY")
	fi

	local joined="${prefix[*]}"
	[[ "$joined" == *"CPUQuota=800%"* ]]
	[[ "$joined" != *"MemoryMax"* ]]
}

@test "resources: only memory non-default adds MemoryMax" {
	CAGE_CPUS="0"
	CAGE_MEMORY="16G"

	local prefix=()
	if [[ "$CAGE_CPUS" != "0" || -n "$CAGE_MEMORY" ]]; then
		prefix=(systemd-run --user --scope -q)
		[[ "$CAGE_CPUS" != "0" ]] && prefix+=(-p "CPUQuota=${CAGE_CPUS}00%")
		[[ -n "$CAGE_MEMORY" ]] && prefix+=(-p "MemoryMax=$CAGE_MEMORY")
	fi

	local joined="${prefix[*]}"
	[[ "$joined" != *"CPUQuota"* ]]
	[[ "$joined" == *"MemoryMax=16G"* ]]
}
