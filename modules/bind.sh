# shellcheck shell=bash
## What a caller may map into a cage, and where.
##
## `enter` takes binds from its caller so that everything a session needs
## beyond the project can be asked for rather than special-cased in nixcage
## (ADR-004). That grants no authority the caller lacks -- it already runs as
## root outside every cage and could invoke nspawn itself -- but the check that
## used to be implicit in "only nixcage's own code adds binds" now has to be
## written down, which is what this file is.
##
## Sourced by store path into nixcage-container.

## Destinations nothing may be mounted over, each for its own reason:
##
##   /                 replacing the rootfs is not a bind, it is another cage
##   /nix              the store and the daemon socket are what makes a session
##                     able to build anything at all
##   /etc/nixcage      the profile, the secret map and the git identity a
##                     session is given; a caller that could replace them could
##                     choose what every later session runs
##   /proc /sys /dev   nspawn's own API mounts, which it manages and which a
##                     bind would leave in a state nothing can reason about
NIXCAGE_BIND_REFUSED="/nix /etc/nixcage /proc /sys /dev"

## The destination half of a SRC:DST pair, or a failure when the spec is not
## one. Exactly one colon: nspawn accepts a third options field, and accepting
## it here would let a caller ask for a writable mount through the read-only
## flag.
nixcage_bind_destination() {
	local spec="$1"
	case "$spec" in
	*:*:*) return 1 ;;
	*:*) ;;
	*) return 1 ;;
	esac
	local dst="${spec#*:}"
	[ -n "$dst" ] || return 1
	printf '%s\n' "$dst"
}

## The source half. Checked only for being an absolute path: what it holds is
## the caller's business, and it is the caller's own filesystem either way.
nixcage_bind_source() {
	local spec="$1"
	local src="${spec%%:*}"
	[ -n "$src" ] || return 1
	printf '%s\n' "$src"
}

nixcage_bind_path_ok() {
	local path="$1"
	case "$path" in
	/*) ;;
	*) return 1 ;;
	esac
	## A relative segment would let a destination that reads as allowed resolve
	## somewhere refused, so it is refused as a spelling rather than resolved.
	case "$path" in
	*/../* | */..) return 1 ;;
	esac
	return 0
}

## Whether a destination may be mounted over. A refused prefix takes its whole
## subtree: /nix/store/x is refused because /nix is.
nixcage_bind_destination_ok() {
	local dst="$1" refused
	nixcage_bind_path_ok "$dst" || return 1
	[ "$dst" != / ] || return 1
	for refused in $NIXCAGE_BIND_REFUSED; do
		[ "$dst" = "$refused" ] && return 1
		case "$dst" in
		"$refused"/*) return 1 ;;
		esac
	done
	return 0
}

## The nspawn argument for one asked-for bind, or a failure naming what was
## wrong with it. Read-only and writable differ only in the flag, so they are
## checked by one function and cannot drift apart.
nixcage_bind_arg() {
	local flag="$1" spec="$2"
	local src dst
	if ! src="$(nixcage_bind_source "$spec")" ||
		! dst="$(nixcage_bind_destination "$spec")"; then
		echo "nixcage: a bind is written SRC:DST, not $spec" >&2
		return 1
	fi
	if ! nixcage_bind_path_ok "$src"; then
		echo "nixcage: bind source must be an absolute path without ..: $src" >&2
		return 1
	fi
	if ! nixcage_bind_destination_ok "$dst"; then
		echo "nixcage: nothing may be mounted at $dst" >&2
		return 1
	fi
	printf '%s=%s:%s\n' "$flag" "$src" "$dst"
}

## An asked-for environment variable. The name is checked because it reaches
## nspawn's own --setenv parsing; the value is not, because any byte is a legal
## value and nspawn takes it as one argument.
##
## What a caller must not put here is a secret: nspawn's argv is readable from
## /proc by any local user, which is why nixcage's own secret map is written
## into the session rootfs instead.
nixcage_setenv_arg() {
	local spec="$1"
	case "$spec" in
	*=*) ;;
	*)
		echo "nixcage: an environment entry is written NAME=VALUE, not $spec" >&2
		return 1
		;;
	esac
	local name="${spec%%=*}"
	if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		echo "nixcage: not a usable environment variable name: $name" >&2
		return 1
	fi
	printf -- '--setenv=%s\n' "$spec"
}
