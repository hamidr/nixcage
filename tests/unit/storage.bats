#!/usr/bin/env bats
# Owned, bounded storage (ADR-017). A caller names a path and a uid; whether
# it gets a dataset or an ordinary directory is nixcage's decision and it is
# never told which.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/storage.sh
	source "$NIXCAGE_ROOT/modules/storage.sh"
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STATE" "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
	printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/chown"
	chmod +x "$STUB_DIR/chown"
}

teardown() {
	teardown_temp_dir
}

# A zfs that records what it was asked and answers about the datasets the test
# says exist. Real ZFS is not available where this suite runs, and what these
# tests are about is which commands are issued, not what ZFS does with them.
stub_zfs() {
	local existing="$*"
	cat >"$STUB_DIR/zfs" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/zfs-calls"
case "\$1" in
list)
	for d in $existing; do
		[ "\${@: -1}" = "\$d" ] && exit 0
	done
	exit 1
	;;
create)
	for arg in "\$@"; do
		case "\$arg" in
		mountpoint=/*) mkdir -p "\${arg#mountpoint=}" ;;
		esac
	done
	exit 0
	;;
esac
exit 0
EOF
	chmod +x "$STUB_DIR/zfs"
}

zfs_calls() {
	cat "$TEST_TEMP_DIR/zfs-calls" 2>/dev/null
}

@test "a dataset name mirrors the path under the state directory" {
	run nixcage_storage_dataset_for "$STATE" nixcage/state "$STATE/worktrees/acme/builder"
	assert_success
	assert_output "nixcage/state/worktrees/acme/builder"
}

@test "a path outside the state directory has no dataset" {
	# The pool is mounted there and nowhere else, so a name invented for a
	# path it does not cover would mount over something nixcage does not own.
	run nixcage_storage_dataset_for "$STATE" nixcage/state /var/lib/elsewhere/x
	assert_failure
}

@test "the state directory itself has no dataset of its own to hand out" {
	run nixcage_storage_dataset_for "$STATE" nixcage/state "$STATE"
	assert_failure
}

@test "every ancestor of a dataset is named, outermost first" {
	run nixcage_storage_ancestors nixcage/state nixcage/state/worktrees/acme/builder
	assert_success
	assert_line --index 0 "nixcage/state/worktrees"
	assert_line --index 1 "nixcage/state/worktrees/acme"
	[ "${#lines[@]}" -eq 2 ]
}

@test "without a pool the path is an ordinary directory" {
	run nixcage_storage_ensure "$STATE" "" "$STATE/worktrees/acme/builder" 700000
	assert_success
	assert_output "$STATE/worktrees/acme/builder"
	[ -d "$STATE/worktrees/acme/builder" ]
}

@test "without a pool a quota is accepted and simply cannot bind" {
	# A Linux host's filesystem is the admin's choice: what is lost is the
	# bound, not the ability to run.
	run nixcage_storage_ensure "$STATE" "" "$STATE/worktrees/acme/builder" 700000 20G
	assert_success
	[ -d "$STATE/worktrees/acme/builder" ]
}

@test "with a pool the path becomes a dataset mounted there" {
	stub_zfs nixcage/state
	run nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000
	assert_success
	assert_output "$STATE/worktrees/acme/builder"
	run zfs_calls
	assert_output --partial "create -o mountpoint=$STATE/worktrees/acme/builder nixcage/state/worktrees/acme/builder"
}

@test "the parents of a new dataset are created mounted nowhere" {
	# A mounted parent would cover the directory holding every sibling.
	stub_zfs nixcage/state
	nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000
	run zfs_calls
	assert_output --partial "create -o mountpoint=none nixcage/state/worktrees"
	assert_output --partial "create -o mountpoint=none nixcage/state/worktrees/acme"
}

@test "a parent two sessions create at once is created by one and accepted by the other" {
	# Two roles' worktrees prepared side by side both reach for the same
	# parent; the second create fails "dataset already exists" and is not
	# a failure of the worktree.
	stub_zfs nixcage/state
	cat >"$STUB_DIR/zfs" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/zfs-calls"
case "\$1" in
list) [ "\${@: -1}" = nixcage/state/worktrees/acme/builder ] && exit 1; exit 0 ;;
create) case "\$*" in *mountpoint=none*) echo "cannot create '\${@: -1}': dataset already exists" >&2; exit 1 ;; esac ;;
esac
exit 0
EOF
	run nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000
	assert_success
	run zfs_calls
	assert_output --partial "create -o mountpoint=$STATE/worktrees/acme/builder nixcage/state/worktrees/acme/builder"
}

@test "a quota is applied whether the dataset is new or not" {
	# One that only took effect on creation would leave everything declared
	# before it unbounded.
	stub_zfs nixcage/state nixcage/state/worktrees/acme/builder
	run nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000 20G
	assert_success
	run zfs_calls
	assert_output --partial "set refquota=20G nixcage/state/worktrees/acme/builder"
	refute_output --partial "create -o mountpoint=$STATE"
}

@test "clearing the quota releases the bound rather than leaving the old one" {
	stub_zfs nixcage/state nixcage/state/worktrees/acme/builder
	nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000
	run zfs_calls
	assert_output --partial "set refquota=none nixcage/state/worktrees/acme/builder"
}

@test "a directory that predates the pool keeps its contents" {
	# Mounting over it would hide the work while leaving something that looks
	# like an empty directory in its place.
	stub_zfs nixcage/state
	mkdir -p "$STATE/worktrees/acme/builder"
	: >"$STATE/worktrees/acme/builder/already-here"
	run nixcage_storage_ensure "$STATE" nixcage/state "$STATE/worktrees/acme/builder" 700000
	assert_success
	assert_output --partial "$STATE/worktrees/acme/builder"
	[ -f "$STATE/worktrees/acme/builder/already-here" ]
	run zfs_calls
	refute_output --partial "create -o mountpoint=$STATE/worktrees/acme/builder"
}

@test "a path the pool does not cover fails loudly rather than silently" {
	stub_zfs nixcage/state
	run nixcage_storage_ensure "$STATE" nixcage/state /var/lib/elsewhere/x 700000
	assert_failure
	assert_output --partial "is outside $STATE"
	[ ! -d /var/lib/elsewhere/x ]
}

# Without a pool the path is still one nixcage owns: storage ensure runs as
# root, and a directory anywhere else is a chown of something that is not
# nixcage's to give.
@test "without a pool a path outside the state directory is refused too" {
	run nixcage_storage_ensure "$STATE" "" "$TEST_TEMP_DIR/elsewhere/x" 700000
	assert_failure
	assert_output --partial "is outside $STATE"
	[ ! -d "$TEST_TEMP_DIR/elsewhere/x" ]
}

@test "without a pool the state directory itself is not handed out" {
	run nixcage_storage_ensure "$STATE" "" "$STATE" 700000
	assert_failure
}

# A directory nixcage gave a uid is written by that uid, which can leave a
# symlink in it. mkdir -p and chown follow one, so a path through it would
# have root make and give away whatever the link names.
@test "a path through a symlink under the state directory is refused" {
	mkdir -p "$STATE/worktrees" "$TEST_TEMP_DIR/target"
	ln -s "$TEST_TEMP_DIR/target" "$STATE/worktrees/acme"
	run nixcage_storage_ensure "$STATE" "" "$STATE/worktrees/acme/builder" 700000
	assert_failure
	assert_output --partial "symlink"
	[ ! -d "$TEST_TEMP_DIR/target/builder" ]
}

@test "a path that is itself a symlink is refused" {
	mkdir -p "$STATE/worktrees" "$TEST_TEMP_DIR/target"
	ln -s "$TEST_TEMP_DIR/target" "$STATE/worktrees/builder"
	run nixcage_storage_ensure "$STATE" "" "$STATE/worktrees/builder" 700000
	assert_failure
	assert_output --partial "symlink"
}

# Inside a machine (ADR-026 decision 3) the disk bounds every cage together,
# and a quota for one of them is refused rather than ignored.

@test "a quota asked inside a machine is refused, naming the machine's disk" {
	run nixcage_storage_quota_refusal 1 10G
	assert_failure
	assert_output "nixcage: a quota cannot be given inside a machine; its disk bounds every cage in it together"
}

@test "no quota inside a machine, or any quota on a host, is not refused here" {
	run nixcage_storage_quota_refusal 1 ""
	assert_success
	run nixcage_storage_quota_refusal "" 10G
	assert_success
}
