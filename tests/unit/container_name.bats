#!/usr/bin/env bats
# container_name_for derives a stable, collision-free container name

load ../test_helper/common

setup() {
	setup_temp_dir
	source_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "same path always yields the same name" {
	a="$(container_name_for /home/me/Src/proj)"
	b="$(container_name_for /home/me/Src/proj)"
	[ "$a" = "$b" ]
}

@test "distinct paths with the same basename yield distinct names" {
	a="$(container_name_for /home/me/Src/proj)"
	b="$(container_name_for /home/me/Work/proj)"
	[ "$a" != "$b" ]
}

@test "name starts with the sanitized basename" {
	name="$(container_name_for "/home/me/Src/My Proj.2")"
	[[ "$name" == My-Proj-2-* ]]
}

@test "name contains only allowed characters" {
	name="$(container_name_for "/home/me/Src/weird !@# name")"
	[[ "$name" =~ ^[a-zA-Z0-9-]+$ ]]
}

@test "basename of only special characters falls back to a default" {
	name="$(container_name_for "/home/me/Src/---")"
	[[ "$name" == project-* ]]
}
