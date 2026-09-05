#!/usr/bin/env bats
# What a caller may map into a cage. `enter` takes binds from whoever calls it,
# so the check that used to be implicit in "only nixcage's own code adds binds"
# is written down here and asserted on.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/bind.sh
	source "$NIXCAGE_ROOT/modules/bind.sh"
}

teardown() {
	teardown_temp_dir
}

@test "a bind is a source and a destination" {
	run nixcage_bind_arg --bind /srv/work:/workspace/work
	assert_success
	assert_output "--bind=/srv/work:/workspace/work"
}

@test "read-only differs from writable only in the flag" {
	run nixcage_bind_arg --bind-ro /srv/work:/workspace/work
	assert_success
	assert_output "--bind-ro=/srv/work:/workspace/work"
}

@test "a bare path is not a bind" {
	run nixcage_bind_arg --bind /srv/work
	assert_failure
	assert_output --partial "written SRC:DST"
}

@test "nspawn's third options field is refused rather than passed on" {
	# Accepting it would let a caller ask for a writable mount through the
	# read-only flag.
	run nixcage_bind_arg --bind-ro /srv/work:/workspace:rbind
	assert_failure
	assert_output --partial "written SRC:DST"
}

@test "a relative destination is refused" {
	run nixcage_bind_arg --bind /srv/work:workspace
	assert_failure
	assert_output --partial "nothing may be mounted at workspace"
}

@test "a destination that climbs out of an allowed place is refused as spelt" {
	run nixcage_bind_arg --bind /srv/work:/workspace/../etc/nixcage
	assert_failure
	assert_output --partial "nothing may be mounted at"
}

@test "the store cannot be mounted over" {
	run nixcage_bind_arg --bind-ro /srv/fake:/nix/store
	assert_failure
	assert_output --partial "nothing may be mounted at /nix/store"
}

@test "nixcage's own configuration cannot be mounted over" {
	# A caller that could replace the profile or the secret map would choose
	# what every later session runs.
	run nixcage_bind_arg --bind-ro /srv/fake:/etc/nixcage/profile
	assert_failure
	assert_output --partial "nothing may be mounted at /etc/nixcage/profile"
}

@test "the rootfs itself cannot be replaced by a bind" {
	run nixcage_bind_arg --bind /srv/fake:/
	assert_failure
}

@test "nspawn's own API mounts cannot be mounted over" {
	for dst in /proc /sys /dev/shm; do
		run nixcage_bind_arg --bind "/srv/fake:$dst"
		assert_failure
	done
}

@test "a place beside a refused one is allowed" {
	# The refusal is a prefix on path segments, not on characters: /etc is
	# not /etc/nixcage and /nixcage-data is not /nix.
	run nixcage_bind_arg --bind-ro /srv/x:/etc/gitconfig
	assert_success
	run nixcage_bind_arg --bind-ro /srv/x:/nixcage-data
	assert_success
}

@test "a relative source is refused" {
	run nixcage_bind_arg --bind srv/work:/workspace/work
	assert_failure
	assert_output --partial "bind source must be an absolute path"
}

@test "an environment entry is a name and a value" {
	run nixcage_setenv_arg CAGEWORKS_TASK=/run/cageworks/task
	assert_success
	assert_output -- "--setenv=CAGEWORKS_TASK=/run/cageworks/task"
}

@test "a value may hold anything, including an equals sign" {
	run nixcage_setenv_arg 'GIT_CONFIG_PARAMETERS=core.x=1'
	assert_success
	assert_output -- "--setenv=GIT_CONFIG_PARAMETERS=core.x=1"
}

@test "an empty value is still a value" {
	run nixcage_setenv_arg "QUIET="
	assert_success
	assert_output -- "--setenv=QUIET="
}

@test "an entry without a value is refused" {
	run nixcage_setenv_arg QUIET
	assert_failure
	assert_output --partial "written NAME=VALUE"
}

@test "a name that is not a name is refused" {
	run nixcage_setenv_arg "not a name=1"
	assert_failure
	assert_output --partial "not a usable environment variable name"
}

@test "a name starting with a digit is refused" {
	run nixcage_setenv_arg "1PATH=/x"
	assert_failure
}
