#!/usr/bin/env bats
# A cage without the daemon sees the closure of its roots and nothing else of
# the store (ADR-014): which paths count as roots, the query that turns roots
# into a closure, and the bind per path that nspawn gets. nix-store is
# stubbed, so the closure is whatever the stub says it is.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/store-closure.sh
	source "$NIXCAGE_ROOT/modules/store-closure.sh"
	CALLS="$TEST_TEMP_DIR/nix-store.calls"
	mkdir -p "$TEST_TEMP_DIR/bin"
	# Answers every root with itself and one shared dependency, unsorted and
	# repeated, as the real query answers two roots that share a library.
	cat >"$TEST_TEMP_DIR/bin/nix-store" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
shift 2
for root; do
  case "\$root" in
  /nix/store/missing-*) echo "error: path '\$root' is not valid" >&2; exit 1 ;;
  esac
  printf '%s\n' "\$root" /nix/store/zzz-glibc
done
STUB
	chmod +x "$TEST_TEMP_DIR/bin/nix-store"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
	teardown_temp_dir
}

@test "a store root is one entry of the store" {
	nixcage_store_root_ok /nix/store/abc-profile
	nixcage_store_root_ok /nix/store/abc-dev-shell.sh
}

@test "the store itself, a path above it, and a path elsewhere are not roots" {
	run nixcage_store_root_ok /nix/store
	assert_failure
	run nixcage_store_root_ok /nix/store/
	assert_failure
	run nixcage_store_root_ok /nix
	assert_failure
	run nixcage_store_root_ok /etc/nixcage/profile
	assert_failure
	run nixcage_store_root_ok nix/store/abc-profile
	assert_failure
}

@test "a relative segment is refused as a spelling, not resolved" {
	run nixcage_store_root_ok /nix/store/abc-profile/../zzz-glibc
	assert_failure
	run nixcage_store_root_ok /nix/store/..
	assert_failure
}

@test "the closure is one query over every root, answered once per path" {
	run nixcage_store_closure /nix/store/abc-profile /nix/store/def-pi
	assert_success
	assert_output "/nix/store/abc-profile
/nix/store/def-pi
/nix/store/zzz-glibc"
	run cat "$CALLS"
	assert_output "--query --requisites /nix/store/abc-profile /nix/store/def-pi"
}

@test "a root the store does not hold fails the closure with nix's own message" {
	run nixcage_store_closure /nix/store/abc-profile /nix/store/missing-tool
	assert_failure
	assert_output --partial "/nix/store/missing-tool' is not valid"
}

@test "each path of the closure is one read-only bind at its own name" {
	run nixcage_store_bind_args /nix/store/abc-profile
	assert_success
	assert_output "--bind-ro=/nix/store/abc-profile
--bind-ro=/nix/store/zzz-glibc"
}

@test "a failed query yields no binds rather than some" {
	run nixcage_store_bind_args /nix/store/missing-tool
	assert_failure
	refute_output --partial "--bind-ro="
}
