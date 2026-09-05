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
## The store is one line per allocation, "<principal> <uid>", where a principal
## that has been forgotten keeps its line under the name "-". Nothing is ever
## removed, because a reissued uid would hand a new principal the files of a
## dead one.

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

## Print the uid for <principal>, allocating one on first use. Allocation is
## strictly increasing, so a forgotten principal's number is never handed out
## again.
nixcage_principal_uid() {
	local store="$1" base="$2" size="$3" principal="$4"

	if ! nixcage_principal_name_ok "$principal"; then
		echo "nixcage: invalid principal name: $principal" >&2
		return 1
	fi

	nixcage_principal_lock "$store" || return 1
	trap 'nixcage_principal_unlock "$store"' RETURN

	[ -f "$store" ] || : >"$store"

	local existing
	existing="$(awk -v r="$principal" '$1 == r { print $2; exit }' "$store")"
	if [ -n "$existing" ]; then
		echo "$existing"
		return 0
	fi

	local highest next
	highest="$(awk 'BEGIN { h = -1 } $2 > h { h = $2 } END { print h }' "$store")"
	if [ "$highest" -lt "$base" ]; then
		next="$base"
	else
		next=$((highest + 1))
	fi

	if [ "$next" -ge $((base + size)) ]; then
		echo "nixcage: uid range $base+$size is exhausted; widen nixcage.principalUidRange" >&2
		return 1
	fi

	printf '%s %s\n' "$principal" "$next" >>"$store"
	echo "$next"
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
	awk -v r="$principal" '{ if ($1 == r) print "- " $2; else print }' "$store" >"$tmp"
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

## The container's /etc/passwd. Rendered here rather than inline so the name
## that reaches it is the validated one.
nixcage_principal_passwd() {
	local login
	login="$(nixcage_principal_login "${1:-}")" || return 1
	printf '%s:x:0:0:%s:/root:/bin/sh\n' "$login" "$login"
	printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
}
