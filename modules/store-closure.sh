# shellcheck shell=bash
## What of the store a session without the daemon sees (ADR-014).
##
## Every session used to bind the whole of /nix/store, so what it could run
## was everything the host held rather than what it was handed. A session
## with the daemon still needs the whole store, since the daemon adds paths
## while the session runs. A session without it needs exactly the closure of
## what it was given: the base profile, the paths its own line names, and
## the roots its caller realised elsewhere. This file turns roots into that
## closure and the closure into the binds nspawn takes.
##
## Sourced by store path into nixcage-container; the suite sources it with
## nix-store stubbed on PATH.

## A root is one entry of the store: absolute, directly under /nix/store,
## with a name. The store itself is not a root, since binding it would be
## the whole-store bind by another spelling, and a relative segment is
## refused rather than resolved for the reason bind.sh gives.
nixcage_store_root_ok() {
	local path="$1"
	case "$path" in
	/nix/store/*) ;;
	*) return 1 ;;
	esac
	local name="${path#/nix/store/}"
	[ -n "$name" ] || return 1
	case "/$name" in
	*/../* | */.. | */./* | */.) return 1 ;;
	esac
	return 0
}

## The closure of the roots, one path per line, each once. One query for
## all the roots rather than one per root, because the roots share most of
## what they close over. A root the store does not hold fails the query,
## and the failure is nix's own message, which names the path.
nixcage_store_closure() {
	[ $# -gt 0 ] || return 1
	local closure
	closure="$(nix-store --query --requisites "$@")" || return 1
	printf '%s\n' "$closure" | sort -u
}

## The nspawn arguments that make the closure visible: a read-only bind of
## each path at its own name, onto the empty /nix/store the rootfs carries.
## Nothing printed on a failed query, so a caller that appends these to a
## line gets no line rather than a shorter one.
nixcage_store_bind_args() {
	local closure
	closure="$(nixcage_store_closure "$@")" || return 1
	local path
	while IFS= read -r path; do
		printf -- '--bind-ro=%s\n' "$path"
	done <<<"$closure"
}

## nixcage_store_bind_given <path...>
## The binds for a closure computed elsewhere: a machine's guest has the
## store without its database, and the host that has it hands the closure
## over (ADR-026). Each path once, and each one there: a path the share
## does not show is refused, since binding it would fail inside nspawn
## with a message about a mount. NIXCAGE_STORE_PREFIX is for the suite.
nixcage_store_bind_given() {
	local path
	local -A seen=()
	for path in "$@"; do
		[ -z "${seen[$path]:-}" ] || continue
		seen[$path]=1
		if [ ! -e "${NIXCAGE_STORE_PREFIX:-}$path" ]; then
			echo "nixcage: the closure names a path this store does not have: $path" >&2
			return 1
		fi
	done
	for path in "$@"; do
		[ -n "${seen[$path]:-}" ] || continue
		unset "seen[$path]"
		printf -- '--bind-ro=%s\n' "$path"
	done
}
