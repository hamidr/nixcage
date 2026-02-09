#!/usr/bin/env bats
# Unit tests for detect_os() (Spec §2.2)

setup() {
	load '../test_helper/common'
	source_nixcage
}

@test "detect_os: returns linux or macos on supported systems" {
	result="$(detect_os)"
	[[ "$result" == "linux" || "$result" == "macos" ]]
}

@test "detect_os: matches uname output" {
	result="$(detect_os)"
	case "$(uname -s)" in
	Linux*) assert_equal "$result" "linux" ;;
	Darwin*) assert_equal "$result" "macos" ;;
	esac
}

@test "OS global is set at source time" {
	[[ "$OS" == "linux" || "$OS" == "macos" ]]
}
