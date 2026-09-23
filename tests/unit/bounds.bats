#!/usr/bin/env bats
# What a cage may use (ADR-022): a size and a count of cpus, resolved per
# enter from the flag, the host's declaration for this cage, and the host's
# default. Nothing is recorded, and nothing is refused: a declaration is a
# default, not a ceiling.

load ../test_helper/common

setup() {
	# shellcheck source=../../modules/bounds.sh
	source "$NIXCAGE_ROOT/modules/bounds.sh"
}

# nixcage_bounds_declared <project> <declarations>
# The declarations are the lines the host rendered, "<path> <memory> <cpus>",
# with "-" where the host said nothing about one of the two.

@test "a cage the host said nothing about declares nothing" {
	run nixcage_bounds_declared /Src/other "/Src/untrusted 8G 8"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "a cage the host declared answers with both quantities" {
	run nixcage_bounds_declared /Src/untrusted "/Src/untrusted 8G 8"
	[ "$output" = "8G 8" ]
}

@test "a declaration of one quantity leaves the other empty" {
	run nixcage_bounds_declared /Src/scratch "/Src/untrusted 8G 8
/Src/scratch 1G -"
	[ "$output" = "1G -" ]
}

@test "the path is matched whole, so a cage under a declared one is not it" {
	run nixcage_bounds_declared /Src/untrusted/inner "/Src/untrusted 8G 8"
	[ "$output" = "" ]
}

# nixcage_bounds_resolve <flag> <declared> <default>
# One quantity at a time, so memory and cpus never borrow each other's source.

@test "nothing given resolves to nothing, which is the substrate's own default" {
	run nixcage_bounds_resolve "" "" ""
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "the host's default answers when nothing closer does" {
	run nixcage_bounds_resolve "" "" 4G
	[ "$output" = 4G ]
}

@test "the cage's declaration beats the host's default" {
	run nixcage_bounds_resolve "" 8G 4G
	[ "$output" = 8G ]
}

@test "the flag beats the cage's declaration" {
	run nixcage_bounds_resolve 2G 8G 4G
	[ "$output" = 2G ]
}

@test "a flag asking for more than the declaration is taken, not refused" {
	run nixcage_bounds_resolve 16G 8G 4G
	[ "$status" -eq 0 ]
	[ "$output" = 16G ]
}

@test "a dash in a declaration means the host said nothing about that one" {
	run nixcage_bounds_resolve "" - 4G
	[ "$output" = 4G ]
}

# The two quantities of a declaration, read apart.

@test "the memory of a declaration is its first word" {
	run nixcage_bounds_field 1 "8G 8"
	[ "$output" = 8G ]
}

@test "the cpus of a declaration is its second word" {
	run nixcage_bounds_field 2 "8G 8"
	[ "$output" = 8 ]
}

@test "a field of an empty declaration is empty" {
	run nixcage_bounds_field 1 ""
	[ "$output" = "" ]
}

@test "a dash reads as nothing rather than as a value" {
	run nixcage_bounds_field 2 "1G -"
	[ "$output" = "" ]
}

# What a machine nobody declared anything about gives a session (ADR-023
# decision 10). ADR-022 declined to choose a number in a module, which does
# not know the machine it will be applied to; this code is standing on the
# machine and reads it. Over a proc root the suite points at fixtures.

write_proc() {
	mkdir -p "$TEST_TEMP_DIR/proc"
	printf 'MemTotal:       %s kB\n' "$1" >"$TEST_TEMP_DIR/proc/meminfo"
	local i
	: >"$TEST_TEMP_DIR/proc/cpuinfo"
	for ((i = 0; i < $2; i++)); do
		printf 'processor\t: %s\n\n' "$i" >>"$TEST_TEMP_DIR/proc/cpuinfo"
	done
}

@test "an undeclared session is given half of what the machine has" {
	setup_temp_dir
	write_proc 16777216 8
	run nixcage_bounds_machine "$TEST_TEMP_DIR/proc"
	[ "$status" -eq 0 ]
	[ "$output" = "8192M 4" ]
	teardown_temp_dir
}

# Half of one core is not a cage, and half of a small machine still has to
# boot a kernel.
@test "a single-core machine still gives a session one cpu" {
	setup_temp_dir
	write_proc 2097152 1
	run nixcage_bounds_machine "$TEST_TEMP_DIR/proc"
	[ "$output" = "1024M 1" ]
	teardown_temp_dir
}

# A machine nixcage cannot read is one it says nothing about, rather than one
# it guesses at: the substrate's own default is then what the session gets,
# which is what ADR-022 left in place.
@test "a machine that cannot be read is not guessed at" {
	setup_temp_dir
	run nixcage_bounds_machine "$TEST_TEMP_DIR/nothing"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	teardown_temp_dir
}
