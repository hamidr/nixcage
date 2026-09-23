#!/usr/bin/env bats
# What a microVM session costs on a host that declared nothing (ADR-023).
# The guest, and the hypervisor where the machine has none, are realised when
# a session first asks for one and cached after that, because a caller who
# never boots a microVM must not pay for one.

load ../test_helper/common

setup() {
	setup_temp_dir
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/declaration"
	export NIXCAGE_LEGACY_HOST_CONFIG="$TEST_TEMP_DIR/legacy-config"
	export NIXCAGE_LEGACY_CONTAINER_CONFIG="$TEST_TEMP_DIR/legacy-container"
	export HOME="$TEST_TEMP_DIR/home"
	export NIXCAGE_CONTAINER=/nix/store/aaa-nixcage-container/bin/nixcage-container
	export NIXCAGE_PROFILE=/nix/store/bbb-nixcage-container-profile
	export NIXCAGE_SELF_FLAKE="github:hamidr/nixcage"
	mkdir -p "$TEST_TEMP_DIR/bin" "$HOME" "$TEST_TEMP_DIR/proj"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/sudo-calls"
EOF
	# One output path per build, named after what was asked for, so a test can
	# tell the guest apart from the hypervisor without parsing the whole line.
	# The paths a build answers with exist, because nixcage checks that what
	# it cached is still there rather than naming a collected path to a
	# session.
	export FAKE_STORE="$TEST_TEMP_DIR/store"
	mkdir -p "$FAKE_STORE/g-nixos-system" "$FAKE_STORE/q-qemu" "$FAKE_STORE/v-virtiofsd" \
		"$FAKE_STORE/o-openssh"
	cat >"$TEST_TEMP_DIR/bin/nix" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/nix-calls"
for word in "\$@"; do
  case "\$word" in
  *#*guest*)      echo "$FAKE_STORE/g-nixos-system" ;;
  *#*qemu*)       echo "$FAKE_STORE/q-qemu" ;;
  *#*virtiofsd*)  echo "$FAKE_STORE/v-virtiofsd" ;;
  *#*openssh*)    echo "$FAKE_STORE/o-openssh" ;;
  esac
done
EOF
	chmod +x "$TEST_TEMP_DIR/bin/sudo" "$TEST_TEMP_DIR/bin/nix"
	cd "$TEST_TEMP_DIR/proj"
}

teardown() {
	teardown_temp_dir
}

# The machine's own hypervisor, which vmspawn finds on PATH for itself.
stub_machine_qemu() {
	printf '#!/usr/bin/env bash\ntrue\n' >"$TEST_TEMP_DIR/bin/qemu-system-$(uname -m)"
	chmod +x "$TEST_TEMP_DIR/bin/qemu-system-$(uname -m)"
}

stub_nixos_version() {
	cat >"$TEST_TEMP_DIR/bin/nixos-version" <<EOF
#!/usr/bin/env bash
echo '{"nixpkgsRevision":"$1"}'
EOF
	chmod +x "$TEST_TEMP_DIR/bin/nixos-version"
}

enter_microvm() {
	run bash -c "yes y | bash '$NIXCAGE_BIN' enter --substrate microvm"
}

@test "a microvm session realises the guest and names it to the session" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--guest $FAKE_STORE/g-nixos-system"* ]]
}

@test "an nspawn session realises nothing" {
	run_nixcage enter
	[ "$status" -eq 0 ]
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
}

@test "what was realised once is not realised again" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	rm "$TEST_TEMP_DIR/nix-calls"
	enter_microvm
	[ "$status" -eq 0 ]
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--guest $FAKE_STORE/g-nixos-system"* ]]
}

# systemd-vmspawn finds its hypervisor itself, so a machine that already runs
# virtual machines needs nothing from nixcage (decision 7).
@test "the machine's own qemu is left to vmspawn to find" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/nix-calls")" != *qemu* ]]
}

@test "a machine without a qemu is told what realising one costs, and asked" {
	run bash -c "echo n | bash '$NIXCAGE_BIN' enter --substrate microvm"
	[ "$status" -ne 0 ]
	[[ "$output" == *1450* ]]
	[[ "$output" == *qemu* ]]
	[ ! -f "$TEST_TEMP_DIR/sudo-calls" ]
}

@test "a machine without a qemu that says yes gets one realised" {
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/nix-calls")" == *qemu* ]]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--microvm-path $FAKE_STORE/q-qemu"* ]]
}

# virtiofsd is what vmspawn shares a directory with, and no host that declared
# nothing has put one anywhere vmspawn looks.
@test "virtiofsd is realised and named to the session" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--microvm-path $FAKE_STORE/v-virtiofsd"* ]]
}

# The guest is built from the revision the host is already running, so its
# glibc, systemd and kernel are store paths the machine already has
# (decision 9).
@test "the guest is built against the revision the host names" {
	stub_machine_qemu
	stub_nixos_version deadbeefcafe
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/nix-calls")" == *"--override-input nixpkgs github:NixOS/nixpkgs/deadbeefcafe"* ]]
}

@test "a host that names no revision gets nixcage's own input, and is told" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/nix-calls")" != *override-input* ]]
	[[ "$output" == *"nixcage's own"* ]]
}

# An option renamed between revisions is a real failure mode, and undeclared
# it lands in the middle of an enter rather than at nixos-rebuild time, so it
# falls back rather than refusing.
@test "a guest that will not build against the host's revision falls back" {
	stub_machine_qemu
	stub_nixos_version deadbeefcafe
	cat >"$TEST_TEMP_DIR/bin/nix" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/nix-calls"
case "\$*" in
*override-input*) echo "error: the option nixcage.nope does not exist" >&2; exit 1 ;;
esac
for word in "\$@"; do
  case "\$word" in
  *#*guest*)     echo $FAKE_STORE/g-nixos-system ;;
  *#*virtiofsd*) echo $FAKE_STORE/v-virtiofsd ;;
  *#*openssh*)   echo $FAKE_STORE/o-openssh ;;
  esac
done
EOF
	chmod +x "$TEST_TEMP_DIR/bin/nix"
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$output" == *deadbeefcafe* ]]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--guest $FAKE_STORE/g-nixos-system"* ]]
}

# A declared host built its guest with nixos-rebuild and put qemu where
# vmspawn looks, which is a decision its administrator made once.
@test "a declared host realises nothing and names nothing" {
	printf 'DECLARATION_VERSION=1\nWORKSPACE_ROOTS=%s\n' "$TEST_TEMP_DIR" \
		>"$NIXCAGE_HOST_CONFIG"
	enter_microvm
	[ "$status" -eq 0 ]
	[ ! -f "$TEST_TEMP_DIR/nix-calls" ]
	local called
	called="$(cat "$TEST_TEMP_DIR/sudo-calls")"
	[[ "$called" != *--guest* ]]
	[[ "$called" != *--microvm-path* ]]
}


@test "an undeclared microvm session is given an ssh to reach the guest with" {
	stub_machine_qemu
	enter_microvm
	[ "$status" -eq 0 ]
	[[ "$(cat "$TEST_TEMP_DIR/nix-calls")" == *openssh* ]]
	[[ "$(cat "$TEST_TEMP_DIR/sudo-calls")" == *"--microvm-path $FAKE_STORE/o-openssh"* ]]
}
