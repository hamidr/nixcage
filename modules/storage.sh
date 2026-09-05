# shellcheck shell=bash
## Datasets for the state nixcage keeps (ADR-017).
##
## A directory nixcage hands to a principal is a dataset of its own where
## nixcage's state is on ZFS, which is what makes a quota possible and what
## keeps an unclean shutdown from leaving that principal's files truncated.
## Where it is not, every function here falls back to an ordinary directory,
## because a Linux host's filesystem is the admin's choice and not nixcage's.
##
## The caller names a path and never a dataset. Which of the two it gets is
## nixcage's decision, and that is the whole reason this is exported rather
## than left to whoever wanted the directory.
##
## Sourced by store path into nixcage-container.

## The dataset a path lives on. The name mirrors the path relative to the state
## directory exactly, so a dataset name can always be read off a path and back.
##
## A path outside the state directory has no dataset: the pool is mounted there
## and nowhere else, and inventing a name for a path the pool does not cover
## would produce a dataset that mounts over something nixcage does not own.
nixcage_storage_dataset_for() {
	local state="$1" root="$2" path="$3"
	[ -n "$root" ] || return 1
	case "$path" in
	"$state"/*) ;;
	*) return 1 ;;
	esac
	echo "$root/${path#"$state"/}"
}

## Answer whether a dataset exists.
nixcage_storage_has_dataset() {
	zfs list -H -o name "$1" >/dev/null 2>&1
}

## Create a dataset that exists only to hold others, mounted nowhere.
##
## Not cosmetic: a mounted parent would cover the directory it mounts on, and
## that directory holds the datasets of every sibling.
nixcage_storage_ensure_container() {
	local dataset="$1"
	nixcage_storage_has_dataset "$dataset" && return 0
	zfs create -o mountpoint=none "$dataset"
}

## Every ancestor of a dataset, outermost first, down to but excluding the
## dataset itself. Each has to exist before the leaf can be created, and each
## is a container rather than something carrying a mountpoint of its own.
nixcage_storage_ancestors() {
	local root="$1" dataset="$2"
	local rest="${dataset#"$root"/}"
	local prefix="$root" segment
	while [ "$rest" != "${rest#*/}" ]; do
		segment="${rest%%/*}"
		prefix="$prefix/$segment"
		echo "$prefix"
		rest="${rest#*/}"
	done
}

## Give <path> to <uid>, as a dataset where there is a pool for one and as an
## ordinary directory where there is not, and bound it by <quota> either way it
## can be bounded.
##
## The quota is applied whether the dataset is new or not: one that only took
## effect on creation would leave everything declared before it unbounded.
## refquota rather than quota, because it bounds what is written there and does
## not count snapshots of that work against it.
nixcage_storage_ensure() {
	local state="$1" root="$2" path="$3" uid="$4" quota="${5:-}"

	local dataset=""
	if [ -n "$root" ]; then
		dataset="$(nixcage_storage_dataset_for "$state" "$root" "$path")" || {
			echo "nixcage: $path is outside $state, which is the only place this pool is mounted" >&2
			return 1
		}
	fi

	if [ -z "$dataset" ]; then
		mkdir -p "$path" || return 1
		chown "$uid:$uid" "$path" || return 1
		echo "$path"
		return 0
	fi

	if ! nixcage_storage_has_dataset "$dataset"; then
		## A directory that predates the pool -- migrated off an older volume,
		## or made before the machine had a dataset to give it -- keeps its
		## contents. Mounting over it would hide them while leaving something
		## that looks like an empty directory in their place.
		if [ -d "$path" ] && [ -n "$(ls -A "$path")" ]; then
			echo "nixcage: $path already holds files; leaving it a directory rather than mounting a dataset over it" >&2
			chown "$uid:$uid" "$path" || return 1
			echo "$path"
			return 0
		fi
		local ancestor
		while IFS= read -r ancestor; do
			[ -n "$ancestor" ] || continue
			nixcage_storage_ensure_container "$ancestor" || return 1
		done < <(nixcage_storage_ancestors "$root" "$dataset")
		zfs create -o "mountpoint=$path" "$dataset" || return 1
	fi

	## Cleared when the caller no longer names one, so what the caller says is
	## the whole truth about the bound.
	zfs set "refquota=${quota:-none}" "$dataset" || return 1
	chown "$uid:$uid" "$path" || return 1
	echo "$path"
}
