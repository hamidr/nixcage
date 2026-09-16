#!/usr/bin/env bats
# The options `enter` is parameterised with (ADR-009). This is the exported
# interface, so what it accepts and what it refuses is asserted directly rather
# than inferred from the session that comes out of it.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/bind.sh
	source "$NIXCAGE_ROOT/modules/bind.sh"
	# shellcheck source=../../modules/store-closure.sh
	source "$NIXCAGE_ROOT/modules/store-closure.sh"
	# shellcheck source=../../modules/enter-args.sh
	source "$NIXCAGE_ROOT/modules/enter-args.sh"
}

teardown() {
	teardown_temp_dir
}

@test "a session with no options is the ordinary one" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_UID" ]
	[ -z "$NIXCAGE_ENTER_USER" ]
	[ -z "$NIXCAGE_ENTER_SUBJECT" ]
	[ -z "$NIXCAGE_ENTER_HOME" ]
	[ "${#NIXCAGE_ENTER_BINDS[@]}" -eq 0 ]
	[ "${#NIXCAGE_ENTER_ENV[@]}" -eq 0 ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
	[ "${NIXCAGE_ENTER_ARGV[1]}" = /srv/myproj ]
}

@test "the uid, the login name and the home are each taken" {
	nixcage_enter_parse --uid 700000 --user builder --home /var/lib/nixcage/homes/x \
		acme-builder /srv/w
	[ "$NIXCAGE_ENTER_UID" = 700000 ]
	[ "$NIXCAGE_ENTER_USER" = builder ]
	[ "$NIXCAGE_ENTER_HOME" = /var/lib/nixcage/homes/x ]
}

@test "binds keep the order they were asked for" {
	# nspawn applies them in order, so a caller mapping one path inside
	# another has to be able to say which comes first.
	nixcage_enter_parse --bind /a:/workspace/a --bind-ro /b:/workspace/b \
		--bind /c:/workspace/c n /srv/w
	[ "${NIXCAGE_ENTER_BINDS[0]}" = "--bind=/a:/workspace/a" ]
	[ "${NIXCAGE_ENTER_BINDS[1]}" = "--bind-ro=/b:/workspace/b" ]
	[ "${NIXCAGE_ENTER_BINDS[2]}" = "--bind=/c:/workspace/c" ]
}

@test "environment entries keep their order too" {
	nixcage_enter_parse --setenv A=1 --setenv B=2 n /srv/w
	[ "${NIXCAGE_ENTER_ENV[0]}" = "--setenv=A=1" ]
	[ "${NIXCAGE_ENTER_ENV[1]}" = "--setenv=B=2" ]
}

@test "a refused bind stops the parse rather than being dropped" {
	run nixcage_enter_parse --bind /a:/nix/store n /srv/w
	assert_failure
	assert_output --partial "nothing may be mounted at /nix/store"
}

@test "a refused environment name stops the parse too" {
	run nixcage_enter_parse --setenv "not a name=1" n /srv/w
	assert_failure
}

@test "an agent socket and refusing one are mutually exclusive" {
	# Resolving them silently would decide a security property by argument
	# order, which is the one thing this must not do.
	run nixcage_enter_parse --auth-sock /tmp/a.sock --no-agent n /srv/w
	assert_failure
	assert_output --partial "mutually exclusive"
	run nixcage_enter_parse --no-agent --auth-sock /tmp/a.sock n /srv/w
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "either one on its own is fine" {
	nixcage_enter_parse --auth-sock /tmp/a.sock n /srv/w
	[ "$NIXCAGE_ENTER_AUTH_SOCK" = /tmp/a.sock ]
	[ -z "$NIXCAGE_ENTER_NO_AGENT" ]
	nixcage_enter_parse --no-agent n /srv/w
	[ -n "$NIXCAGE_ENTER_NO_AGENT" ]
	[ -z "$NIXCAGE_ENTER_AUTH_SOCK" ]
}

@test "a uid that is not a number is refused" {
	run nixcage_enter_parse --uid root n /srv/w
	assert_failure
	assert_output --partial "not a uid: root"
}

@test "a home that could climb out of the state directory is refused" {
	run nixcage_enter_parse --home /var/lib/nixcage/homes/../../../etc n /srv/w
	assert_failure
	assert_output --partial "not a usable home path"
}

@test "a session command spelt like one of our own flags is left alone" {
	# Options precede the positionals, so everything past the first
	# non-option word belongs to the caller whatever it looks like.
	nixcage_enter_parse --uid 700000 n /srv/w agent --no-agent --setenv X
	[ "$NIXCAGE_ENTER_UID" = 700000 ]
	[ -z "$NIXCAGE_ENTER_NO_AGENT" ]
	[ "${#NIXCAGE_ENTER_ENV[@]}" -eq 0 ]
	[ "${NIXCAGE_ENTER_ARGV[2]}" = agent ]
	[ "${NIXCAGE_ENTER_ARGV[3]}" = "--no-agent" ]
	[ "${NIXCAGE_ENTER_ARGV[5]}" = X ]
}

@test "a session command survives spaces and newlines" {
	nixcage_enter_parse n /srv/w sh -c "$(printf 'echo one\necho two')"
	[ "${NIXCAGE_ENTER_ARGV[4]}" = "$(printf 'echo one\necho two')" ]
	[ "${#NIXCAGE_ENTER_ARGV[@]}" -eq 5 ]
}

@test "a parse does not inherit what the last one produced" {
	nixcage_enter_parse --uid 700000 --bind /a:/workspace/a n /srv/w
	nixcage_enter_parse n /srv/w
	[ -z "$NIXCAGE_ENTER_UID" ]
	[ "${#NIXCAGE_ENTER_BINDS[@]}" -eq 0 ]
}

@test "a session can name the subject it runs as" {
	nixcage_enter_parse --subject agent myproj /srv/myproj
	[ "$NIXCAGE_ENTER_SUBJECT" = agent ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
}

@test "a subject that could forge a passwd line is refused at the boundary" {
	run nixcage_enter_parse --subject "root:x:0:0::/:/bin/sh" myproj /srv/myproj
	assert_failure
	assert_output --partial "not a subject name"
	run nixcage_enter_parse --subject "../escape" myproj /srv/myproj
	assert_failure
}

@test "naming no subject leaves the session as cage root" {
	nixcage_enter_parse --uid 700000 myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_SUBJECT" ]
}

# A cage on a private network (cageworks ADR-037). The caller names the bridge
# and the one address the cage gets on it; nixcage owns the veth and sets the
# address inside, so what a caller can ask for is a placement and nothing else.

@test "given a bridge and an address, a session is placed on that bridge at that address" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 myproj /srv/myproj
	[ "$NIXCAGE_ENTER_NETWORK_BRIDGE" = cageworks-acme ]
	[ "$NIXCAGE_ENTER_NETWORK_ADDR" = 10.77.0.4/24 ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
}

# The network of a cage already running (cageworks: a person entering a role
# whose actor holds the role's one veth and address). The caller names the
# namespace by path; nixcage joins it and sets nothing, since the cage that
# owns it did.
@test "given a namespace path, a session joins that network and is placed on no bridge" {
	nixcage_enter_parse --network ns:/proc/4242/ns/net myproj /srv/myproj
	[ "$NIXCAGE_ENTER_NETWORK_NS" = /proc/4242/ns/net ]
	[ -z "$NIXCAGE_ENTER_NETWORK_BRIDGE" ]
	[ -z "$NIXCAGE_ENTER_NETWORK_ADDR" ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
}

@test "when the namespace path is not absolute, the network is refused" {
	run nixcage_enter_parse --network ns:proc/4242/ns/net myproj /srv/myproj
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a network namespace"* ]]
}

@test "a parse without a network does not inherit the last one's namespace" {
	nixcage_enter_parse --network ns:/proc/4242/ns/net myproj /srv/myproj
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_NETWORK_NS" ]
}

@test "given no network option, a session has no bridge and no address" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_NETWORK_BRIDGE" ]
	[ -z "$NIXCAGE_ENTER_NETWORK_ADDR" ]
}

@test "when the address carries no prefix, the network is refused" {
	run nixcage_enter_parse --network cageworks-acme:10.77.0.4 myproj /srv/myproj
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a bridge placement"* ]]
}

@test "when the bridge name could not be an interface, the network is refused" {
	run nixcage_enter_parse --network "a-name-far-too-long-for-an-interface:10.77.0.4/24" myproj /srv/myproj
	[ "$status" -ne 0 ]
	run nixcage_enter_parse --network "br/acme:10.77.0.4/24" myproj /srv/myproj
	[ "$status" -ne 0 ]
}

@test "when the placement has no colon, the network is refused" {
	run nixcage_enter_parse --network cageworks-acme myproj /srv/myproj
	[ "$status" -ne 0 ]
}

# A cage without the nix daemon (cageworks ADR-037): nothing inside can build
# or fetch, so a tool reaches a cage through the flake or not at all.

@test "given no daemon is asked for, a session records that it has none" {
	nixcage_enter_parse --no-nix-daemon myproj /srv/myproj
	[ "$NIXCAGE_ENTER_NO_NIX_DAEMON" = 1 ]
}

@test "given no option, a session keeps its daemon" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_NO_NIX_DAEMON" ]
}

@test "when a devShell is named without a daemon, the pair is refused rather than resolved" {
	run nixcage_enter_parse --shell backend --no-nix-daemon myproj /srv/myproj
	[ "$status" -ne 0 ]
	[[ "$output" == *"--shell and --no-nix-daemon are mutually exclusive"* ]]
	run nixcage_enter_parse --no-nix-daemon --shell backend myproj /srv/myproj
	[ "$status" -ne 0 ]
}

@test "a network and no daemon together are fine" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --no-nix-daemon myproj /srv/myproj
	[ "$NIXCAGE_ENTER_NETWORK_BRIDGE" = cageworks-acme ]
	[ "$NIXCAGE_ENTER_NO_NIX_DAEMON" = 1 ]
}

@test "a parse without a network does not inherit the last one's placement" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --no-nix-daemon myproj /srv/myproj
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_NETWORK_BRIDGE" ]
	[ -z "$NIXCAGE_ENTER_NETWORK_ADDR" ]
	[ -z "$NIXCAGE_ENTER_NO_NIX_DAEMON" ]
}

# A cage bounded on the scope nspawn gives it (ADR-012): two properties the
# caller sizes, refused when they could not be a size or a count.
@test "given memory and cpus, a session carries them as properties of its scope" {
	nixcage_enter_parse --memory 4G --cpus 2 myproj /srv/myproj
	[ "$NIXCAGE_ENTER_MEMORY" = 4G ]
	[ "$NIXCAGE_ENTER_CPUS" = 2 ]
	run nixcage_enter_property_args
	assert_line --index 0 "--property=MemoryMax=4G"
	assert_line --index 1 "--property=CPUQuota=200%"
}

@test "given neither bound, a session sets no property and is bounded by the machine" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_MEMORY" ]
	[ -z "$NIXCAGE_ENTER_CPUS" ]
	run nixcage_enter_property_args
	assert_output ""
}

@test "when the memory is not a size, the session is refused" {
	run nixcage_enter_parse --memory lots myproj /srv/myproj
	assert_failure
	assert_output --partial "not a memory size: lots"
}

@test "when the cpu count is not a positive integer, the session is refused" {
	run nixcage_enter_parse --cpus 1.5 myproj /srv/myproj
	assert_failure
	assert_output --partial "not a cpu count: 1.5"
	run nixcage_enter_parse --cpus 0 myproj /srv/myproj
	assert_failure
}

# The composed nspawn line as a contract a dependant can test against
# (ADR-012 consequence): asked for, the session is printed and not run.
@test "given --print-argv, a session records that it is to be printed, not run" {
	nixcage_enter_parse --print-argv myproj /srv/myproj
	[ "$NIXCAGE_ENTER_PRINT_ARGV" = 1 ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
}

@test "given no --print-argv, a session runs" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_PRINT_ARGV" ]
}

@test "given --store-root, a session records each root in order" {
	nixcage_enter_parse --store-root /nix/store/abc-profile \
		--store-root /nix/store/def-pi n /srv/w
	[ "${#NIXCAGE_ENTER_STORE_ROOTS[@]}" = 2 ]
	[ "${NIXCAGE_ENTER_STORE_ROOTS[0]}" = "/nix/store/abc-profile" ]
	[ "${NIXCAGE_ENTER_STORE_ROOTS[1]}" = "/nix/store/def-pi" ]
}

@test "given no --store-root, a session has none" {
	nixcage_enter_parse n /srv/w
	[ "${#NIXCAGE_ENTER_STORE_ROOTS[@]}" = 0 ]
}

@test "a store root outside the store stops the parse" {
	run nixcage_enter_parse --store-root /etc/nixcage/profile n /srv/w
	assert_failure
	assert_output --partial "not a store path: /etc/nixcage/profile"
}

# What a private-network cage resolves with (ADR-016). The rootfs used to
# carry the host's file, which names a resolver a cage on a bridge cannot
# reach, so every lookup waited out the resolver's timeout and then failed.

@test "given a bridge placement and --dns none, the session records no resolver" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --dns none myproj /srv/myproj
	[ "$NIXCAGE_ENTER_DNS" = none ]
	[ "${NIXCAGE_ENTER_ARGV[0]}" = myproj ]
}

@test "given a bridge placement and a resolver address, the session records that address" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --dns 10.77.0.1 myproj /srv/myproj
	[ "$NIXCAGE_ENTER_DNS" = 10.77.0.1 ]
}

@test "given a namespace path and a resolver address, the session records that address" {
	nixcage_enter_parse --network ns:/proc/4242/ns/net --dns 10.77.0.1 myproj /srv/myproj
	[ "$NIXCAGE_ENTER_DNS" = 10.77.0.1 ]
}

@test "a resolver that is a name, a port, or an IPv6 address is refused" {
	for dns in resolver.example 10.77.0.1:53 fd00::1 300.1.1.1; do
		run nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --dns "$dns" myproj /srv/myproj
		[ "$status" -ne 0 ]
		[[ "$output" == *"not a resolver address: $dns"* ]]
	done
}

@test "--dns without --network is refused in either order, because the host's resolver would contradict it" {
	run nixcage_enter_parse --dns none myproj /srv/myproj
	[ "$status" -ne 0 ]
	[[ "$output" == *"--dns needs --network"* ]]
	run nixcage_enter_parse --dns 10.77.0.1 --no-nix-daemon myproj /srv/myproj
	[ "$status" -ne 0 ]
}

@test "a private-network session with no --dns resolves nothing, in either shape" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 myproj /srv/myproj
	[ "$NIXCAGE_ENTER_DNS" = none ]
	nixcage_enter_parse --network ns:/proc/4242/ns/net myproj /srv/myproj
	[ "$NIXCAGE_ENTER_DNS" = none ]
}

@test "a session in the host's namespace records no resolver choice, so it keeps the host's" {
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_DNS" ]
}

@test "a parse inherits no resolver from the last one" {
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --dns 10.77.0.1 myproj /srv/myproj
	nixcage_enter_parse myproj /srv/myproj
	[ -z "$NIXCAGE_ENTER_DNS" ]
}

# The file the rootfs gets, written from the parse rather than copied.
@test "a host-namespace rootfs carries the host's resolv.conf byte for byte" {
	printf 'nameserver 192.0.2.53\nsearch example.test\n# a comment\n' >"$TEST_TEMP_DIR/host.conf"
	nixcage_enter_parse myproj /srv/myproj
	nixcage_enter_resolv_conf "$TEST_TEMP_DIR/host.conf" "$TEST_TEMP_DIR/resolv.conf"
	cmp "$TEST_TEMP_DIR/host.conf" "$TEST_TEMP_DIR/resolv.conf"
}

@test "a host without a resolv.conf leaves the rootfs without one, as before" {
	nixcage_enter_parse myproj /srv/myproj
	nixcage_enter_resolv_conf "$TEST_TEMP_DIR/absent.conf" "$TEST_TEMP_DIR/resolv.conf"
	[ ! -e "$TEST_TEMP_DIR/resolv.conf" ]
}

@test "a private-network rootfs carries an empty resolv.conf" {
	printf 'nameserver 192.0.2.53\n' >"$TEST_TEMP_DIR/host.conf"
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 myproj /srv/myproj
	nixcage_enter_resolv_conf "$TEST_TEMP_DIR/host.conf" "$TEST_TEMP_DIR/resolv.conf"
	[ -f "$TEST_TEMP_DIR/resolv.conf" ]
	[ ! -s "$TEST_TEMP_DIR/resolv.conf" ]
}

@test "a rootfs told a resolver carries one nameserver line and nothing else" {
	printf 'nameserver 192.0.2.53\nsearch example.test\n' >"$TEST_TEMP_DIR/host.conf"
	nixcage_enter_parse --network cageworks-acme:10.77.0.4/24 --dns 10.77.0.1 myproj /srv/myproj
	nixcage_enter_resolv_conf "$TEST_TEMP_DIR/host.conf" "$TEST_TEMP_DIR/resolv.conf"
	run cat "$TEST_TEMP_DIR/resolv.conf"
	assert_output "nameserver 10.77.0.1"
}
