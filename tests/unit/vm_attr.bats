#!/usr/bin/env bats
# resolve_vm_attr prefers nixcage-<hostname> and falls back to nixcage

load ../test_helper/common

setup() {
	setup_temp_dir
	source_nixcage
	# Stub nix so the probe answers without evaluating a real flake.
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
	teardown_temp_dir
}

stub_nix_probe() {
	local answer="$1"
	cat >"$TEST_TEMP_DIR/bin/nix" <<EOF
#!/usr/bin/env bash
echo $answer
EOF
	chmod +x "$TEST_TEMP_DIR/bin/nix"
}

@test "host-specific configuration wins when the flake has one" {
	stub_nix_probe true
	run resolve_vm_attr
	[ "$status" -eq 0 ]
	[ "$output" = "nixosConfigurations.\"nixcage-$(hostname -s)\".config" ]
}

@test "falls back to the shared nixcage configuration" {
	stub_nix_probe false
	run resolve_vm_attr
	[ "$status" -eq 0 ]
	[ "$output" = "nixosConfigurations.nixcage.config" ]
}

@test "probe failure falls back instead of aborting" {
	cat >"$TEST_TEMP_DIR/bin/nix" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$TEST_TEMP_DIR/bin/nix"
	run resolve_vm_attr
	[ "$status" -eq 0 ]
	[ "$output" = "nixosConfigurations.nixcage.config" ]
}
