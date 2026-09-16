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
