# shellcheck shell=bash
## Allocation of the uid a cage is mapped onto (ADR-004).
##
## A principal is whatever the caller wants a durable uid for: nixcage does not
## know what it is, only that the same name must always answer with the same
## number and that no number is ever handed to a second name.
##
## Sourced by store path into nixcage-container, and by bats directly, which
## is why it is a file rather than an inline string.
##
## The store is one line per allocation, "<principal> <uid> <size>", where a
## principal that has been forgotten keeps its line under the name "-".
## Nothing is ever removed, because a reissued uid would hand a new principal
## the files of a dead one.
##
## A line written before blocks existed carries no size and reads as one,
## which is what it was. That is what lets a host allocated under ADR-004
## upgrade without a cage mapping the neighbour it was packed against.

## Principal names index the store, appear in paths, and are joined into
## container names, so they share the alphabet nixcage-container's own
## check_name accepts. Anything outside it is refused rather than escaped.
nixcage_principal_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]
}

## mkdir is the portable atomic test-and-set; the guest has flock but the test
## suite runs on the developer's machine, which may not.
nixcage_principal_lock() {
	local lock="$1.lock" waited=0
	while ! mkdir "$lock" 2>/dev/null; do
		waited=$((waited + 1))
		if [ "$waited" -gt 500 ]; then
			echo "nixcage: uid store is locked: $lock" >&2
			return 1
		fi
		sleep 0.01
	done
}

nixcage_principal_unlock() {
	rmdir "$1.lock" 2>/dev/null || true
}

## The size of the block an entry holds. A line from before ADR-010 has two
## fields and holds one uid.
nixcage_principal_entry_size() {
	awk -v r="$1" '$1 == r { print ($3 == "" ? 1 : $3); exit }' "$2"
}

## The size of the block allocated at <uid>. A uid the store never handed out
## holds one and no more: an ordinary project session is mapped onto the owner
## of a directory, which was never allocated here at all. This is what a cage
## maps, rather than the width the host currently declares, because a block is
## fixed when it is allocated and the uid after a narrow one belongs to
## somebody else.
nixcage_principal_size_at() {
	local store="$1" uid="$2" size

	if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
		echo "nixcage: not a uid: $uid" >&2
		return 1
	fi

	if [ -f "$store" ]; then
		size="$(awk -v u="$uid" '$2 == u { print ($3 == "" ? 1 : $3); exit }' "$store")"
	fi
	echo "${size:-1}"
}

## Print the base of <principal>'s block, allocating one on first use. A block
## is placed above every block already allocated, so a number is never handed
## out twice and a forgotten principal's block is never reused.
nixcage_principal_uid() {
	local store="$1" base="$2" size="$3" principal="$4" block="${5:-1}"

	if ! nixcage_principal_name_ok "$principal"; then
		echo "nixcage: invalid principal name: $principal" >&2
		return 1
	fi

	if ! [[ "$block" =~ ^[0-9]+$ ]] || [ "$block" -lt 1 ]; then
		echo "nixcage: not a block size: $block" >&2
		return 1
	fi

	nixcage_principal_lock "$store" || return 1
	trap 'nixcage_principal_unlock "$store"' RETURN

	[ -f "$store" ] || : >"$store"

	## An existing principal keeps the block it was allocated. Widening one in
	## place would walk into whatever was allocated after it.
	local existing
	existing="$(awk -v r="$principal" '$1 == r { print $2; exit }' "$store")"
	if [ -n "$existing" ]; then
		echo "$existing"
		return 0
	fi

	## The cursor is the highest end reached, not the highest base: a block's
	## size is what says where the next one may start.
	local highest next
	highest="$(awk '
		BEGIN { h = -1 }
		{ end = $2 + ($3 == "" ? 1 : $3); if (end > h) h = end }
		END { print h }
	' "$store")"
	if [ "$highest" -lt "$base" ]; then
		next="$base"
	else
		next="$highest"
	fi

	## The guard tests the block's end. One on the base alone would admit a
	## block that starts inside the range and finishes outside it.
	if [ $((next + block)) -gt $((base + size)) ]; then
		echo "nixcage: uid range $base+$size is exhausted; widen nixcage.principalUidRange" >&2
		return 1
	fi

	printf '%s %s %s\n' "$principal" "$next" "$block" >>"$store"
	echo "$next"
}

## The number a subject carries, by its offset inside its principal's block.
## Offset 0 is the principal itself. An offset the block does not cover is
## refused rather than computed, so a principal allocated before subjects
## existed cannot be given one after the fact.
nixcage_principal_subject_uid() {
	local store="$1" principal="$2" offset="$3"

	nixcage_principal_name_ok "$principal" || return 1
	if ! [[ "$offset" =~ ^[0-9]+$ ]]; then
		echo "nixcage: not a subject offset: $offset" >&2
		return 1
	fi
	[ -f "$store" ] || return 1

	local base block
	base="$(awk -v r="$principal" '$1 == r { print $2; exit }' "$store")"
	[ -n "$base" ] || return 1
	block="$(nixcage_principal_entry_size "$principal" "$store")"

	if [ "$offset" -ge "$block" ]; then
		echo "nixcage: $principal holds a block of $block; no subject at $offset" >&2
		return 1
	fi

	echo $((base + offset))
}

## Where a declared subject sits inside a block. Cage root is offset 0 and is
## never declared, so the first declared subject is 1.
nixcage_principal_subject_offset() {
	local subject="$1" offset=0 declared

	nixcage_principal_name_ok "$subject" || return 1

	for declared in ${2:-}; do
		offset=$((offset + 1))
		nixcage_principal_name_ok "$declared" || return 1
		if [ "$declared" = "$subject" ]; then
			echo "$offset"
			return 0
		fi
	done

	echo "nixcage: no such subject: $subject" >&2
	return 1
}

## Forget a principal without freeing its number: the line stays so the uid
## stays claimed, and the files it owns can still be traced to something.
nixcage_principal_forget() {
	local store="$1" principal="$2"

	nixcage_principal_name_ok "$principal" || return 1
	[ -f "$store" ] || return 0

	nixcage_principal_lock "$store" || return 1
	trap 'nixcage_principal_unlock "$store"' RETURN

	local tmp="$store.tmp.$$"
	awk -v r="$principal" '
		{ if ($1 == r) print "-", $2, ($3 == "" ? 1 : $3); else print }
	' "$store" >"$tmp"
	mv "$tmp" "$store"
}

## The login uid 0 carries inside a cage. An ordinary project session stays
## root; a session entered for a named principal is named after it, so the
## prompt, the process table, and anything resolving the uid say who is
## running.
nixcage_principal_login() {
	if [ -z "${1:-}" ]; then
		echo root
	else
		nixcage_principal_name_ok "$1" || return 1
		echo "$1"
	fi
}

## The container's /etc/passwd. Rendered here rather than inline so every name
## that reaches it is a validated one. Cage root comes first, then one line per
## declared subject at the offset the block gives it.
nixcage_principal_passwd() {
	local login subject offset=0
	login="$(nixcage_principal_login "${1:-}")" || return 1
	printf '%s:x:0:0:%s:/root:/bin/sh\n' "$login" "$login"
	for subject in ${2:-}; do
		offset=$((offset + 1))
		nixcage_principal_name_ok "$subject" || return 1
		## Two lines under one name would make which uid a name resolves to
		## depend on which the reader found first.
		if [ "$subject" = "$login" ]; then
			echo "nixcage: subject $subject collides with the session login" >&2
			return 1
		fi
		printf '%s:x:%s:%s:%s:/home/%s:/bin/sh\n' \
			"$subject" "$offset" "$offset" "$subject" "$subject"
	done
	printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
}

## The container's /etc/group, one group per subject so an id resolves to a
## name on both sides of a file's ownership.
nixcage_principal_group() {
	local subject offset=0
	printf 'root:x:0:\n'
	for subject in ${1:-}; do
		offset=$((offset + 1))
		nixcage_principal_name_ok "$subject" || return 1
		printf '%s:x:%s:\n' "$subject" "$offset"
	done
	printf 'nogroup:x:65534:\n'
}
