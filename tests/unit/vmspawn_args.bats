#!/usr/bin/env bats
# The vmspawn line a microvm session runs (ADR-019): a second assembler from
# the parse enter-args.sh produces, printed one word per line as the nspawn
# line is, so a dependant asserts what nixcage makes of its flags.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/scope.sh
	source "$NIXCAGE_ROOT/modules/scope.sh"
	# shellcheck source=../../modules/vmspawn-args.sh
	source "$NIXCAGE_ROOT/modules/vmspawn-args.sh"
}

teardown() {
	teardown_temp_dir
}

# nixcage_vmspawn_credential <uid> <gid> <home> <cwd> <tty> <address> <agent> [--setenv=K=V...] -- <argv...>

@test "the credential carries who runs what where, as one JSON object" {
	run nixcage_vmspawn_credential 700000 700000 /root /workspace 1 "" "" \
		--setenv=HOME=/root --setenv=PATH=/nix/store/x/bin -- bash -c 'echo "hi"'
	assert_success
	assert_output '{"uid":700000,"gid":700000,"home":"/root","cwd":"/workspace","tty":true,"agent":false,"env":{"HOME":"/root","PATH":"/nix/store/x/bin"},"argv":["bash","-c","echo \"hi\""]}'
}

@test "an address is in the credential only when the session was placed" {
	run nixcage_vmspawn_credential 1000 100 /root /workspace 0 10.0.0.2/24 "" -- true
	assert_output '{"uid":1000,"gid":100,"home":"/root","cwd":"/workspace","tty":false,"address":"10.0.0.2/24","agent":false,"env":{},"argv":["true"]}'
}

@test "a session with an agent forwarded says so, and the guest waits for the socket" {
	run nixcage_vmspawn_credential 1000 100 /root /workspace 0 "" 1 -- true
	assert_output '{"uid":1000,"gid":100,"home":"/root","cwd":"/workspace","tty":false,"agent":true,"env":{},"argv":["true"]}'
}

@test "a value with a newline or a quote survives the credential" {
	run nixcage_vmspawn_credential 1 1 /root /w 0 "" "" --setenv=MSG=$'a\nb"c' -- true
	assert_output '{"uid":1,"gid":1,"home":"/root","cwd":"/w","tty":false,"agent":false,"env":{"MSG":"a\nb\"c"},"argv":["true"]}'
}

@test "the credential is bounded by what the SMBIOS path carries" {
	# Measured: a 48000-byte credential reaches the guest beside what
	# vmspawn adds, a 49000-byte one takes them all down with it. The
	# constant leaves room for vmspawn's own to grow.
	[ "$NIXCAGE_VMSPAWN_CREDENTIAL_MAX" -eq 32768 ]
	local big
	big="$(head -c 40000 /dev/zero | tr '\0' x)"
	run nixcage_vmspawn_credential_ok "$big"
	assert_failure
	assert_output --partial "session credential is 40000 bytes; the SMBIOS path carries 32768"
	run nixcage_vmspawn_credential_ok "$(head -c 32768 /dev/zero | tr '\0' x)"
	assert_success
}

# nixcage_vmspawn_args <name> <skeleton> <toplevel> <credential> <uid> <block> <tty> <memory> <cpus> <disk> [bind words...]

@test "the line boots the host's guest over the skeleton with the session credential" {
	run nixcage_vmspawn_args myproj-1a2b3c4d /var/lib/nixcage/containers/myproj-1a2b3c4d/session-42 \
		/nix/store/abc-nixos-system-guest /var/lib/nixcage/containers/myproj-1a2b3c4d/session-42.cred \
		700000 65536 1 "" "" "" \
		--bind=/srv/myproj:/workspace --bind=/var/lib/nixcage/homes/myproj-1a2b3c4d:/root
	assert_success
	assert_line --index 0 "env"
	assert_line --index 1 "SYSTEMD_VMSPAWN_QEMU_EXTRA=-append 'root=root rootfstype=virtiofs rw init=/nix/store/abc-nixos-system-guest/init console=hvc0 loglevel=0 systemd.show_status=0 systemd.log_target=null TERM=dumb'"
	assert_line --index 2 "systemd-vmspawn"
	assert_line --index 3 "--quiet"
	assert_line --index 4 "--register=yes"
	assert_line --index 5 "--machine=myproj-1a2b3c4d"
	assert_line --index 6 "--directory=/var/lib/nixcage/containers/myproj-1a2b3c4d/session-42"
	assert_line --index 7 "--linux=/nix/store/abc-nixos-system-guest/kernel"
	assert_line --index 8 "--initrd=/nix/store/abc-nixos-system-guest/initrd"
	assert_line --index 9 "--firmware=none"
	assert_line --index 10 "--private-users=700000:65536"
	assert_line --index 11 "--console=interactive"
	assert_line --index 12 "--load-credential=nixcage.session:/var/lib/nixcage/containers/myproj-1a2b3c4d/session-42.cred"
	assert_line --index 13 "--bind-ro=/nix/store"
	assert_line --index 14 "--bind=/srv/myproj:/workspace"
	assert_line --index 15 "--bind=/var/lib/nixcage/homes/myproj-1a2b3c4d:/root"
	[ "${#lines[@]}" -eq 16 ]
}

@test "without a tty the console is read-only, so the output is captured and nothing is typed" {
	run nixcage_vmspawn_args n /s /t /c 1 1 0 "" "" ""
	refute_line "--console=interactive"
	assert_line "--console=read-only"
}

@test "bounds are the guest's own, not properties of the scope" {
	run nixcage_vmspawn_args n /s /t /c 1 1 0 4G 2 ""
	assert_line "--ram=4G"
	assert_line "--cpus=2"
	refute_line --partial "MemoryMax"
	refute_line --partial "CPUQuota"
}

@test "a disk is handed in as an extra drive" {
	run nixcage_vmspawn_args n /s /t /c 1 1 0 "" "" /var/lib/nixcage/disks/n/disk.img
	assert_line "--extra-drive=/var/lib/nixcage/disks/n/disk.img"
}

@test "the binds are nspawn's words unchanged" {
	# bind.sh produces them and the two spawns read the same syntax; a
	# file cannot cross virtiofs, and that is checked where the file is.
	run nixcage_vmspawn_args n /s /t /c 1 1 0 "" "" "" --bind-ro=/a:/b --bind=/c
	assert_line "--bind-ro=/a:/b"
	assert_line "--bind=/c"
}
