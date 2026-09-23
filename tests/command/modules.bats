#!/usr/bin/env bats
# The bridge a cage may be placed on, declared to the host module or the VM
# module (ADR-018). Both are evaluated for real as NixOS systems, since
# what is asserted is what NixOS renders from the option: the address, the
# carrier setting an empty bridge needs, the sysctl, and a refusal.

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

# nix eval --json of an attribute set over one module's configuration.
# $1 is host or vm, $2 the extra configuration, $3 the expression over sys.
# nix's own chatter goes to stderr, which is shown only when eval fails,
# since a refusal's message is there.
eval_module() {
	local modules
	case "$1" in
	host) modules='flake.nixosModules.host' ;;
	vm) modules='flake.inputs.microvm.nixosModules.microvm flake.nixosModules.nixcage' ;;
	esac
	nix eval --impure --json --expr "
		let
		  flake = builtins.getFlake \"path:$NIXCAGE_ROOT\";
		  sys = flake.inputs.nixpkgs.lib.nixosSystem {
		    system = \"x86_64-linux\";
		    modules = [ $modules { nixcage.workspaceRoots = [ \"/srv\" ]; } ($2) ];
		  };
		in $3" 2>"$TEST_TEMP_DIR/eval.err" || {
		cat "$TEST_TEMP_DIR/eval.err"
		return 1
	}
}

ONE_BRIDGE='{ nixcage.bridges.fabriek0 = { address = "10.77.0.1"; prefix = 24; }; }'
RENDERED='{
  ports = sys.config.networking.bridges.fabriek0.interfaces;
  addresses = sys.config.networking.interfaces.fabriek0.ipv4.addresses;
  carrier = sys.config.systemd.network.networks."40-fabriek0".networkConfig.ConfigureWithoutCarrier;
  sysctl = sys.config.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" or null;
  tcp = sys.config.networking.firewall.interfaces.fabriek0.allowedTCPPorts or [ ];
}'

@test "the host module renders a declared bridge with no ports, its address, carrier without ports, and the sysctl" {
	run eval_module host "$ONE_BRIDGE" "$RENDERED"
	assert_success
	[ "$(jq -c .ports <<<"$output")" = "[]" ]
	[ "$(jq -c .addresses <<<"$output")" = '[{"address":"10.77.0.1","prefixLength":24}]' ]
	[ "$(jq .carrier <<<"$output")" = true ]
	[ "$(jq .sysctl <<<"$output")" = 1 ]
}

@test "the VM module renders the same bridge into the guest" {
	run eval_module vm "$ONE_BRIDGE" "$RENDERED"
	assert_success
	[ "$(jq -c .addresses <<<"$output")" = '[{"address":"10.77.0.1","prefixLength":24}]' ]
	[ "$(jq .carrier <<<"$output")" = true ]
	[ "$(jq .sysctl <<<"$output")" = 1 ]
}

@test "nixcage opens no port on the bridge: what a cage may reach there is the host's firewall" {
	run eval_module host "$ONE_BRIDGE" "$RENDERED"
	assert_success
	[ "$(jq -c .tcp <<<"$output")" = "[]" ]
}

@test "with no bridge declared, both modules declare no bridge and set no sysctl" {
	local module
	for module in host vm; do
		run eval_module "$module" '{ }' '{ bridges = sys.config.networking.bridges; sysctl = sys.config.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" or null; }'
		assert_success
		assert_output '{"bridges":{},"sysctl":null}'
	done
}

@test "a bridge name of sixteen characters is refused at evaluation, as enter --network refuses it" {
	run eval_module host '{ nixcage.bridges.a-name-of-16chrs = { address = "10.77.0.1"; prefix = 24; }; }' 'sys.config.networking.bridges'
	assert_failure
	assert_output --partial "not an interface name"
	run eval_module host '{ nixcage.bridges."br/acme" = { address = "10.77.0.1"; prefix = 24; }; }' 'sys.config.networking.bridges'
	assert_failure
}

# The guest a microvm session boots (ADR-019): one NixOS system per host,
# built by the host module from its own pkgs when asked, never otherwise.
MICROVM='{ nixcage.microvm.enable = true; nixcage.principalUidRange.base = 700000; }'
GUEST='sys.config.nixcage.microvm.guest.config'

@test "with microvm enabled, the host module names the guest it built in the container config" {
	run eval_module host "$MICROVM" 'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *"MICROVM_GUEST=/nix/store/"*"-nixos-system-nixcage-guest-"* ]]
	[[ "$(jq -r . <<<"$output")" == *"SUBSTRATE_DEFAULT=nspawn"* ]]
}

@test "the host's default substrate is what the config carries" {
	run eval_module host '{ nixcage.microvm.enable = true; nixcage.substrate.default = "microvm"; nixcage.principalUidRange.base = 700000; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *"SUBSTRATE_DEFAULT=microvm"* ]]
}

@test "with microvm off, no guest is built and the config names none" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000; }' 'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" != *"MICROVM_GUEST"* ]]
	[[ "$(jq -r . <<<"$output")" == *"SUBSTRATE_DEFAULT=nspawn"* ]]
}

@test "a default of microvm with microvm off is refused at evaluation" {
	run eval_module host '{ nixcage.substrate.default = "microvm"; nixcage.principalUidRange.base = 700000; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_failure
	assert_output --partial "nixcage.substrate.default is microvm but nixcage.microvm.enable is false"
}

@test "the guest's root is the virtiofs tag vmspawn exports, and what it writes dies with the session" {
	run eval_module host "$MICROVM" "{
	  root = $GUEST.fileSystems.\"/\";
	  etc = $GUEST.fileSystems.\"/etc\".fsType;
	  var = $GUEST.fileSystems.\"/var\".fsType;
	  tmp = $GUEST.fileSystems.\"/tmp\".fsType;
	  initrd = $GUEST.boot.initrd.kernelModules;
	}"
	assert_success
	[ "$(jq -r .root.device <<<"$output")" = root ]
	[ "$(jq -r .root.fsType <<<"$output")" = virtiofs ]
	[ "$(jq -r '[.etc,.var,.tmp] | unique | .[]' <<<"$output")" = tmpfs ]
	# Credentials come as SMBIOS strings, which the kernel shows only with
	# dmi_sysfs, and the initrd's mounts come as one of them.
	[[ "$(jq -c .initrd <<<"$output")" == *'"dmi_sysfs"'* ]]
	[[ "$(jq -c .initrd <<<"$output")" == *'"virtiofs"'* ]]
}

@test "the guest has no nix daemon and no getty on the console the session owns" {
	run eval_module host "$MICROVM" "{
	  nix = $GUEST.nix.enable;
	  getty = $GUEST.systemd.services.\"serial-getty@hvc0\".enable;
	}"
	assert_success
	[ "$(jq .nix <<<"$output")" = false ]
	[ "$(jq .getty <<<"$output")" = false ]
}

@test "the session unit reads the credential, runs as part of boot, and the guest's sshd answers on vsock with store paths" {
	run eval_module host "$MICROVM" "{
	  cred = $GUEST.systemd.services.nixcage-session.serviceConfig.LoadCredential;
	  wanted = $GUEST.systemd.services.nixcage-session.wantedBy;
	  sshdPre = $GUEST.systemd.services.\"sshd-vsock@\".serviceConfig.ExecStartPre;
	  sshd = $GUEST.systemd.services.\"sshd-vsock@\".serviceConfig.ExecStart;
	  strategy = $GUEST.systemd.services.\"sshd-vsock@\".overrideStrategy;
	  oom = $GUEST.systemd.services.nixcage-session.serviceConfig.OOMPolicy;
	}"
	assert_success
	[ "$(jq -r .oom <<<"$output")" = continue ]
	[ "$(jq -r '.cred' <<<"$output")" = "nixcage.session" ]
	[[ "$(jq -c .wanted <<<"$output")" == *'"multi-user.target"'* ]]
	[ "$(jq -r '.sshdPre[0]' <<<"$output")" = "" ]
	[[ "$(jq -r '.sshdPre[1]' <<<"$output")" == "+/nix/store/"* ]]
	[[ "$(jq -r '.sshd[1]' <<<"$output")" == "-/nix/store/"*"/bin/sshd -i"* ]]
	[ "$(jq -r .strategy <<<"$output")" = asDropin ]
}

@test "a cage declared with a substrate is rendered for the container script, path and word" {
	# The declaration outranks the record and the flag (ADR-019 decision
	# 2); it reaches the script as one line per cage in the config it
	# already reads.
	run eval_module host '{ nixcage.microvm.enable = true; nixcage.principalUidRange.base = 700000;
	  nixcage.cages."/srv/trusted".substrate = "nspawn"; nixcage.cages."/srv/untrusted".substrate = "microvm"; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *'CAGE_SUBSTRATES="/srv/trusted nspawn
/srv/untrusted microvm"'* ]]
}

@test "a cage declared microvm on a host that builds no guest is refused at evaluation" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000; nixcage.cages."/srv/x".substrate = "microvm"; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_failure
	assert_output --partial "nixcage.cages./srv/x.substrate is microvm but nixcage.microvm.enable is false"
}

# What a cage may use (ADR-022). Both platform modules render the default,
# because both run the same container layer; only the host module has cages
# to declare bounds for one at a time.

@test "the host's default bounds are rendered for the container script" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000;
	  nixcage.bounds = { memory = "4G"; cpus = 4; }; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *'BOUNDS_DEFAULT="4G 4"'* ]]
}

@test "a quantity the host left unset is rendered as nothing said" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000;
	  nixcage.bounds.memory = "4G"; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *'BOUNDS_DEFAULT="4G -"'* ]]
}

@test "a cage's own bounds are rendered, path and both quantities" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000;
	  nixcage.cages."/srv/big".bounds = { memory = "8G"; cpus = 8; };
	  nixcage.cages."/srv/small".bounds.memory = "1G"; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *'CAGE_BOUNDS="/srv/big 8G 8
/srv/small 1G -"'* ]]
}

@test "a size nixcage cannot hand to systemd is refused at evaluation" {
	run eval_module host '{ nixcage.principalUidRange.base = 700000;
	  nixcage.bounds.memory = "4GiB"; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_failure
}

@test "the VM module renders the default too, for the cages inside it" {
	# authorizedKeys has no default and environment.etc is one merged option,
	# so the VM's sshd definition is forced along with the file under test.
	run eval_module vm '{ nixcage.principalUidRange.base = 700000;
	  nixcage.authorizedKeys = [ "ssh-ed25519 AAAA test" ];
	  nixcage.bounds = { memory = "2G"; cpus = 2; }; }' \
		'sys.config.environment.etc."nixcage/declaration".text'
	assert_success
	[[ "$(jq -r . <<<"$output")" == *'BOUNDS_DEFAULT="2G 2"'* ]]
}

# Where nothing was declared there is no module to install the container
# layer, so the layer is what nixcage itself carries (ADR-023). Evaluated for
# real: a flake that stopped exporting it would otherwise be found by whoever
# ran nix run on a machine that declared nothing.
@test "the flake exports the container layer a session is built from" {
	run nix eval --raw "$NIXCAGE_ROOT#packages.x86_64-linux.container.drvPath"
	assert_success
	run nix eval --raw "$NIXCAGE_ROOT#packages.x86_64-linux.containerProfile.drvPath"
	assert_success
}

@test "the linux CLI is built with the layer named in its environment" {
	run nix eval --json \
		"$NIXCAGE_ROOT#packages.x86_64-linux.default.drvPath" \
		--apply 'p: p'
	assert_success
	run grep -qE -- '--set NIXCAGE_CONTAINER' "$NIXCAGE_ROOT/flake.nix"
	assert_success
	run grep -qE -- '--set NIXCAGE_PROFILE' "$NIXCAGE_ROOT/flake.nix"
	assert_success
}

# A microVM session on a host that declared nothing realises these by name
# (ADR-023 decision 6), so a flake that stopped exporting one would be found
# in the middle of an enter rather than here.
@test "the flake exports what a microvm session is realised from" {
	for attr in guest qemu virtiofsd; do
		run nix eval --raw "$NIXCAGE_ROOT#packages.x86_64-linux.$attr.drvPath"
		assert_success
	done
}


# An undeclared session's git identity is read from the invoking user's own
# git (ADR-023 decision 11), so the CLI has to have one to ask.
@test "the CLI carries the git it reads an identity with" {
	run nix eval --json "$NIXCAGE_ROOT#packages.x86_64-linux.default.drvPath"
	assert_success
	run bash -c "sed -n '/runtimeDeps = with pkgs/,/];/p' '$NIXCAGE_ROOT/flake.nix' | grep -qx '            git'"
	assert_success
}


# The one check that boots a cage rather than describing one (task of this
# round). It cannot run on a macOS host, so what is asserted here is that it
# still evaluates: a test nobody can build is a test nobody runs.
@test "the flake carries the checks that boot a machine" {
	for check in cage primitives; do
		run nix eval --raw "$NIXCAGE_ROOT#checks.x86_64-linux.$check.drvPath"
		assert_success
	done
}
