#!/usr/bin/env bats
# A machine (ADR-026): a long-lived microVM that is a nixcage host. What the
# host reads of its declaration, the line that boots it, the state the host
# reports for it, and the words a verb is forwarded into it with.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/scope.sh
	source "$NIXCAGE_ROOT/modules/scope.sh"
	# shellcheck source=../../modules/microvm-session.sh
	source "$NIXCAGE_ROOT/modules/microvm-session.sh"
	# shellcheck source=../../modules/machine.sh
	source "$NIXCAGE_ROOT/modules/machine.sh"
	export NIXCAGE_MACHINES_DIR="$TEST_TEMP_DIR/machines"
	mkdir -p "$NIXCAGE_MACHINES_DIR"
	cat >"$NIXCAGE_MACHINES_DIR/m1" <<-EOF
		TOPLEVEL=/nix/store/abc-machine-m1
		MEMORY=2G
		CPUS=2
		DISK_SIZE=20G
		UID_BASE=900000
		UID_SIZE=65536
		STORE_BASE=/nix/store/aaa-profile /nix/store/bbb-dev-shell
	EOF
}

teardown() {
	teardown_temp_dir
}

# nixcage_machine_read <name>

@test "a declared machine is read into the fields its line is built from" {
	nixcage_machine_read m1
	[ "$MACHINE_TOPLEVEL" = /nix/store/abc-machine-m1 ]
	[ "$MACHINE_MEMORY" = 2G ]
	[ "$MACHINE_CPUS" = 2 ]
	[ "$MACHINE_DISK_SIZE" = 20G ]
	[ "$MACHINE_UID_BASE" = 900000 ]
	[ "$MACHINE_UID_SIZE" = 65536 ]
	[ "$MACHINE_STORE_BASE" = "/nix/store/aaa-profile /nix/store/bbb-dev-shell" ]
}

@test "a machine this host did not declare is refused by name" {
	run nixcage_machine_read m2
	assert_failure
	assert_output "nixcage: this host declares no machine m2"
}

@test "a machine's name is held to a cage's spelling before any file is looked for" {
	run nixcage_machine_read "../m1"
	assert_failure
	assert_output "nixcage: invalid machine name: ../m1"
}

@test "a declaration missing its toplevel is refused rather than booted as nothing" {
	sed -i '/^TOPLEVEL=/d' "$NIXCAGE_MACHINES_DIR/m1"
	run nixcage_machine_read m1
	assert_failure
	assert_output "nixcage: machine m1's declaration names no TOPLEVEL"
}

# nixcage_machine_vmspawn_args <name> <skeleton> <toplevel> <uid base> <uid size> <memory> <cpus> <disk> <extra>

@test "a machine boots its own init with systemd's readiness, under its slice" {
	run nixcage_machine_vmspawn_args m1 /var/lib/nixcage/machines/m1/root \
		/nix/store/abc-machine-m1 900000 65536 2G 2 /var/lib/nixcage/machines/m1/disk.img ""
	assert_success
	assert_line "--machine=m1"
	assert_line "--notify-ready=yes"
	assert_line "--directory=/var/lib/nixcage/machines/m1/root"
	assert_line "--linux=/nix/store/abc-machine-m1/kernel"
	assert_line "--initrd=/nix/store/abc-machine-m1/initrd"
	assert_line "--private-users=900000:65536"
	assert_line "--ram=2G"
	assert_line "--cpus=2"
	assert_line "--extra-drive=/var/lib/nixcage/machines/m1/disk.img"
	assert_line "--bind-ro=/nix/store"
	assert_line --partial "init=/nix/store/abc-machine-m1/init"
}

@test "a machine's console is nobody's: it is read, never attached" {
	run nixcage_machine_vmspawn_args m1 /r /nix/store/abc-machine-m1 900000 65536 "" "" /d ""
	assert_success
	assert_line "--console=read-only"
	refute_line --partial "--ram="
	refute_line --partial "--cpus="
}

@test "a machine's journal is kept, unlike a session's, which logs nowhere" {
	run nixcage_machine_vmspawn_args m1 /r /nix/store/abc-machine-m1 900000 65536 "" "" /d ""
	refute_output --partial "systemd.log_target=null"
}

# nixcage_machine_state <unit active state> <probe status>

@test "an active unit whose guest answers is ready" {
	run nixcage_machine_state active 0
	assert_output ready
}

@test "an active unit whose guest does not answer yet is booting" {
	run nixcage_machine_state active 1
	assert_output booting
}

@test "an activating unit is booting whatever the probe says" {
	run nixcage_machine_state activating 0
	assert_output booting
}

@test "a deactivating unit is stopping" {
	run nixcage_machine_state deactivating 0
	assert_output stopping
}

@test "a failed unit is failed and an inactive one is off" {
	run nixcage_machine_state failed 1
	assert_output failed
	run nixcage_machine_state inactive 1
	assert_output off
}

# nixcage_machine_forward_words <key> <address> <tty> <agent> -- <remote argv...>

@test "a forward is ssh over vsock as the guest's root, each word quoted for its shell" {
	run nixcage_machine_forward_words /run/key vsock/7 "" "" -- nixcage-container list --json
	assert_success
	assert_line ssh
	assert_line -i
	assert_line /run/key
	assert_line root@vsock/7
	assert_line "nixcage-container list --json"
	refute_line -t
}

@test "a word with a space or a quote reaches the guest as one word" {
	run nixcage_machine_forward_words /run/key vsock/7 "" "" -- echo "a b" "it's"
	assert_line "echo a\\ b it\\'s"
}

@test "a forward from a terminal asks ssh for one" {
	run nixcage_machine_forward_words /run/key vsock/7 1 "" -- bash
	assert_line -t
}

@test "an agent is carried as a remote socket forward to the path the guest is told" {
	run nixcage_machine_forward_words /run/key vsock/7 "" "/run/nixcage/agent-1.sock:/tmp/agent.sock" -- true
	assert_line -R
	assert_line /run/nixcage/agent-1.sock:/tmp/agent.sock
}

# nixcage_machine_enter_words <closure> <guest agent path> <enter args...>

@test "an enter forwarded to a machine has no daemon and is handed its closure" {
	run nixcage_machine_enter_words "/nix/store/aaa-p:/nix/store/ccc-q" "" --memory 1G c1 /srv/p true
	assert_success
	[ "${lines[0]}" = enter ]
	[ "${lines[1]}" = --no-nix-daemon ]
	[ "${lines[2]}" = --store-closure ]
	[ "${lines[3]}" = "/nix/store/aaa-p:/nix/store/ccc-q" ]
	[ "${lines[4]}" = --memory ]
	[ "${lines[7]}" = /srv/p ]
}

@test "a host path for the agent is replaced by the guest's, where the forward lands" {
	run nixcage_machine_enter_words "/nix/store/aaa-p" /run/nixcage/agent-9.sock \
		--auth-sock /tmp/agent.sock c1 /srv/p
	assert_line /run/nixcage/agent-9.sock
	refute_line /tmp/agent.sock
}

@test "a caller's own --no-nix-daemon is not said twice" {
	run nixcage_machine_enter_words "/nix/store/aaa-p" "" --no-nix-daemon c1 /srv/p
	[ "$(printf '%s\n' "${lines[@]}" | grep -c -- --no-nix-daemon)" -eq 1 ]
}

@test "a session command spelt like the flag is left to the session" {
	run nixcage_machine_enter_words "/nix/store/aaa-p" /run/g.sock c1 /srv/p --auth-sock /tmp/x
	assert_line /tmp/x
}
