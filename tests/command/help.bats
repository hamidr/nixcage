#!/usr/bin/env bats
# Command tests for help & version (Spec §3.1)

setup() {
	load '../test_helper/common'
}

@test "help: prints usage information" {
	run_nixcage help
	assert_success
	assert_output --partial "nixcage"
	assert_output --partial "Usage:"
	assert_output --partial "Commands:"
}

@test "--help: same as help" {
	run_nixcage --help
	assert_success
	assert_output --partial "Usage:"
}

@test "-h: same as help" {
	run_nixcage -h
	assert_success
	assert_output --partial "Usage:"
}

@test "help: lists all commands" {
	run_nixcage help
	assert_success
	assert_output --partial "init"
	assert_output --partial "reinit"
	assert_output --partial "destroy"
	assert_output --partial "shell"
	assert_output --partial "run"
	assert_output --partial "status"
}

@test "help: shows quick start section" {
	run_nixcage help
	assert_success
	assert_output --partial "Quick start"
}

@test "version: prints version string" {
	run_nixcage version
	assert_success
	assert_output --partial "nixcage 0.3.0"
}

@test "--version: same as version" {
	run_nixcage --version
	assert_success
	assert_output --partial "nixcage 0.3.0"
}

@test "no arguments: shows help" {
	run_nixcage
	assert_success
	assert_output --partial "Usage:"
}

@test "list-presets: lists claude-code" {
	run_nixcage list-presets
	assert_success
	assert_output --partial "claude-code"
}

@test "help: mentions list-presets command" {
	run_nixcage help
	assert_success
	assert_output --partial "list-presets"
}
