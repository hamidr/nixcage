#!/usr/bin/env bats
# The interface nixcage exports, asserted against the guest script's source.
#
# The behaviour lives in enter_args.bats, bind.bats, storage.bats and
# principal_uid.bats, which drive it. What is left over is the shape: which
# verbs the guest script dispatches, and whether a flag the parser accepts is
# one a caller could ever have found. Both are the way an exported interface
# usually breaks -- something is renamed for a reason that looked local, and
# the dependant finds out at run time -- and neither is visible from a test
# that only calls functions.

load ../test_helper/common

CONTAINER_NIX() { echo "$NIXCAGE_ROOT/modules/container.nix"; }
ENTER_ARGS() { echo "$NIXCAGE_ROOT/modules/enter-args.sh"; }

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "the exported verbs are dispatched" {
	# enter builds a session, uid names a principal's number, storage gives a
	# path to that number. Everything built on nixcage is built on these.
	for verb in enter uid storage; do
		run grep -qE "^      $verb\)" "$(CONTAINER_NIX)"
		assert_success
	done
}

@test "list and rm stay, because the CLI still calls them" {
	for verb in list rm; do
		run grep -qE "^      $verb\)" "$(CONTAINER_NIX)"
		assert_success
	done
}

@test "enter accepts every flag a caller parameterises a session with" {
	for flag in --uid --user --subject --home --shell --bind --bind-ro --setenv --no-agent --auth-sock; do
		run grep -qE "^$(printf '\t\t')$flag\)" "$(ENTER_ARGS)"
		assert_success
	done
}

@test "every flag enter accepts is in its usage line" {
	# The usage line is the only description of this interface a caller sees
	# at run time, so a flag missing from it is a flag nobody finds.
	local usage
	usage="$(grep -o 'usage: nixcage-container enter[^"]*' "$(CONTAINER_NIX)" | head -1)"
	[ -n "$usage" ]
	local flags
	flags="$(grep -oE "^$(printf '\t\t')--[a-z-]+\)" "$(ENTER_ARGS)" |
		tr -d "$(printf '\t')" | tr -d ')')"
	[ -n "$flags" ]
	for flag in $flags; do
		[[ "$usage" == *"$flag"* ]] || {
			echo "the usage line does not mention: $flag"
			return 1
		}
	done
}

@test "the parser is a file the suite can drive, not a loop in a Nix string" {
	# An interface nothing can drive breaks at a dependant's run time rather
	# than at ours.
	[ -f "$(ENTER_ARGS)" ]
	run grep -q 'nixcage_enter_parse "$@"' "$(CONTAINER_NIX)"
	assert_success
}

@test "asked-for binds and environment go through the check rather than around it" {
	# A --bind that reached nspawn without nixcage_bind_arg would be the whole
	# widened surface with none of the refusals on it.
	run grep -c 'nixcage_bind_arg' "$(ENTER_ARGS)"
	assert_output "2"
	run grep -c 'nixcage_setenv_arg' "$(ENTER_ARGS)"
	assert_output "1"
}

@test "the storage verb never lets a caller name a dataset" {
	# Which of a dataset and a directory a path becomes is nixcage's decision.
	run grep -qE 'storage ensure <path> <uid> \[quota\]' "$(CONTAINER_NIX)"
	assert_success
	run grep -c 'zfs ' "$(CONTAINER_NIX)"
	assert_output "0"
}

@test "the uid store carries its allocations across the rename" {
	# Renaming it without moving it would reallocate every number, and a
	# reissued uid hands something new the files of something dead.
	run grep -q 'mv "$STATE_DIR/role-uids" "$store"' "$(CONTAINER_NIX)"
	assert_success
}

@test "the cage maps the block a principal was allocated, not a fixed one" {
	# A mapping of one where the block is wider leaves the subjects unmapped;
	# a fixed wider one would map whatever was allocated next door (ADR-010).
	run grep -q -- '--private-users="\$owner_uid:\$block"' "$(CONTAINER_NIX)"
	assert_success
	# The width comes from what this uid was allocated, not from what the host
	# declares now: a principal allocated narrower sits against its neighbour.
	run grep -q 'nixcage_principal_size_at "$(uid_store)" "$owner_uid"' "$(CONTAINER_NIX)"
	assert_success
}

@test "uid answers for a subject without the caller doing arithmetic" {
	# A caller names principals and subjects; nixcage names numbers (ADR-009).
	run grep -qE 'uid <principal> \[<subject>\]' "$(CONTAINER_NIX)"
	assert_success
	run grep -q 'nixcage_principal_subject_uid' "$(CONTAINER_NIX)"
	assert_success
}

@test "every verb that reads the host's declaration reads it first" {
	# What /etc/nixcage/container declares is not ambient: read_container_config
	# sources it, and a verb that skips the call sees every variable in it as
	# empty. cmd_enter resolves --subject against PRINCIPAL_SUBJECTS and writes
	# an /etc/passwd entry per declared subject, so it needs the file as much as
	# uid and storage do.
	#
	# Skipping it fails in the worst available way: the subject list is empty,
	# so the offset loop never runs and every --subject is refused as "no such
	# subject" while the host's own configuration names it. ADR-010 point 6 is
	# unreachable for exactly as long as this is missing.
	for verb in enter uid storage; do
		run awk "/^      cmd_$verb\(\) \{/,/^      \}\$/" "$(CONTAINER_NIX)"
		assert_success
		assert_output --partial "read_container_config"
	done
}

@test "the rootfs carries getent where this systemd looks for it" {
	# nspawn resolves any user but root by exec'ing getent inside the
	# container, and nixpkgs patches that search to Nix profile locations
	# rather than /usr/bin/getent and /bin/getent. Every one of them is absent
	# from a rootfs this builds, so the exec fails, the helper returns nothing
	# and nspawn reports "Failed to resolve user" for a name its own
	# /etc/passwd carries.
	#
	# /etc/profiles/per-user/root is the search path that survives: nspawn
	# mounts a tmpfs over /run, and resolution happens as root before the
	# session drops to a subject.
	run grep -q "etc/profiles/per-user/root/bin/getent" "$(CONTAINER_NIX)"
	assert_success
}

@test "shipped code models no caller's concept" {
	# ADR-009's consequence: nixcage stops having an opinion about what is
	# built on it. A caller's word for its own actors -- a role, a task, a
	# factory -- appearing in a code path or an error message means nixcage is
	# modelling something on the far side of the interface, and the next
	# dependant with a different word finds a cage that talks about roles.
	#
	# The word is allowed only where it names the dependant that has it
	# (cageworks) or the store renamed away from it (role-uids), so every
	# surviving occurrence says on its own line why it is there.
	local shipped=(
		"$NIXCAGE_ROOT/nixcage"
		"$NIXCAGE_ROOT"/modules/*.sh
		"$NIXCAGE_ROOT"/modules/*.nix
		"$NIXCAGE_ROOT/templates/config/flake.nix"
	)
	run grep -nEi '\broles?\b' "${shipped[@]}"
	local line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		[[ "$line" == *role-uids* || "$line" == *cageworks* ]] ||
			fail "names a caller's concept: $line"
	done <<<"$output"
}

@test "the session userland carries the tools a session reaches for" {
	# coreutils has none of sed, grep, awk or xargs; they are gnused,
	# gnugrep, gawk and findutils. A project with a devShell never notices,
	# because mkShell inherits stdenv and stdenv carries all four. ADR-005
	# makes a devShell optional, so a project without one gets a session
	# where the ordinary text tools are simply absent.
	for pkg in gnused gnugrep gawk findutils; do
		run grep -qE "^      $pkg\$" "$(CONTAINER_NIX)"
		assert_success
	done
}

@test "a host can add to the session userland without editing this layer" {
	# A dependant that needs one more thing in every cage has no way to put
	# it there: enter takes binds and environment, not packages, and
	# prepending PATH means reconstructing the profile path it does not know.
	# The alternative is nixcage growing an opinion about what belongs in
	# somebody else's cage, which ADR-009 exists to prevent.
	run grep -q "extraPackages" "$(CONTAINER_NIX)"
	assert_success

	for m in host.nix nixcage.nix; do
		run grep -q "containerPackages" "$NIXCAGE_ROOT/modules/$m"
		assert_success
	done
}
