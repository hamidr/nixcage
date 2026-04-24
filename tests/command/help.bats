#!/usr/bin/env bats
# Command tests for help & version

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

@test "help: lists v1 commands" {
	run_nixcage help
	assert_success
	assert_output --partial "init"
	assert_output --partial "build"
	assert_output --partial "start"
	assert_output --partial "stop"
	assert_output --partial "shell"
	assert_output --partial "run"
	assert_output --partial "sync"
	assert_output --partial "status"
	assert_output --partial "install-hook"
	assert_output --partial "destroy"
}

@test "help: shows quick start section" {
	run_nixcage help
	assert_success
	assert_output --partial "Quick start"
}

@test "version: prints version string" {
	run_nixcage version
	assert_success
	assert_output --partial "nixcage 1.0.0"
}

@test "--version: same as version" {
	run_nixcage --version
	assert_success
	assert_output --partial "nixcage 1.0.0"
}

@test "no arguments: shows help" {
	run_nixcage
	assert_success
	assert_output --partial "Usage:"
}
