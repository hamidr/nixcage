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
