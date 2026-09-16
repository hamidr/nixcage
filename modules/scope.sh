# shellcheck shell=bash
## A cage has a scope, and nixcage answers for it (ADR-012).
##
## nspawn runs every container in a transient scope unit named after the
## machine, under machine.slice, whether or not it is registered with
## machined. That scope is where the cage's processes are and where its
## bounds are set, so the verbs over a running cage read it and nothing
## else: no process table, no argv of nspawn's.
##
## And a cage has a record of what enter was given (ADR-017), under its
## state directory, which list --json joins with the scope: the uid and
## subject the caller named, the placement, the roots. Written before nspawn
## starts, overwritten by the next enter under the name, removed by rm, so
## a stopped cage still says what it was given.
##
## Sourced by store path into nixcage-container. The cgroup and proc roots
## and the state directory are variables so the suite drives these on a
## fixture tree.

NIXCAGE_CGROUP_ROOT="${NIXCAGE_CGROUP_ROOT:-/sys/fs/cgroup}"
NIXCAGE_PROC="${NIXCAGE_PROC:-/proc}"
NIXCAGE_STATE_DIR="${NIXCAGE_STATE_DIR:-/var/lib/nixcage}"

## The alphabet check_name allows is one systemd does not escape, so the
## unit name is the cage's name and no escaping is written.
nixcage_scope_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9-]+$ ]]
}

## nspawn names the scope machine-<name>.scope when machined registers the
## cage and <name>.scope when told --register=no, and which depends on the
## systemd at hand (261 does the latter). Both are asked, and the one that
## is active is the cage's; when neither is, the registered spelling stands
## for what the name would be.
nixcage_scope_unit() {
	nixcage_scope_name_ok "$1" || return 1
	if [ "$(systemctl show -p ActiveState --value "$1.scope" 2>/dev/null)" = active ]; then
		printf '%s.scope\n' "$1"
	else
		printf 'machine-%s.scope\n' "$1"
	fi
}

## The cgroup of a unit, or of the cage's unit when given a name.
nixcage_scope_cgroup() {
	local unit
	case "$1" in
	*.scope) unit="$1" ;;
	*) unit="$(nixcage_scope_unit "$1")" || return 1 ;;
	esac
	printf 'machine.slice/%s\n' "$unit"
}

## The cage's active unit, or nothing.
nixcage_scope_active_unit() {
	local unit
	unit="$(nixcage_scope_unit "$1")" || return 1
	[ "$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)" = active ] || return 1
	printf '%s\n' "$unit"
}

## One field of a process's status file, as the kernel writes it.
nixcage_scope_proc_field() {
	local pid="$1" field="$2"
	sed -n "s/^$field:[[:space:]]*//p" "$NIXCAGE_PROC/$pid/status" 2>/dev/null
}

## The cage's first process: the one in the scope whose parent is nspawn.
## Older nspawn sits in the scope itself beside its child; systemd 261's
## stays outside and puts the cage under <scope>/payload/. Both places are
## read, the scope's own first; nspawn is known by its name, wherever it is.
nixcage_scope_leader() {
	local cgroup pid parent procs
	cgroup="$(nixcage_scope_cgroup "$1")" || return 1
	for procs in "$NIXCAGE_CGROUP_ROOT/$cgroup/cgroup.procs" "$NIXCAGE_CGROUP_ROOT/$cgroup/payload/cgroup.procs"; do
		[ -r "$procs" ] || continue
		while IFS= read -r pid; do
			[ -n "$pid" ] || continue
			parent="$(nixcage_scope_proc_field "$pid" PPid)"
			[ -n "$parent" ] || continue
			if [ "$(nixcage_scope_proc_field "$parent" Name)" = systemd-nspawn ]; then
				printf '%s\n' "$pid"
				return 0
			fi
		done <"$procs"
	done
	return 1
}

## running <leader> <cgroup>, or stopped. Asked of the scope first so a
## stopped cage reads no cgroup.
nixcage_scope_status() {
	local name="$1" leader
	nixcage_scope_name_ok "$name" || {
		echo "nixcage: invalid container name: $name" >&2
		return 1
	}
	local unit
	unit="$(nixcage_scope_active_unit "$name")" || {
		echo stopped
		return 0
	}
	leader="$(nixcage_scope_leader "$unit")" || {
		echo stopped
		return 0
	}
	printf 'running %s %s\n' "$leader" "$(nixcage_scope_cgroup "$unit")"
}

## The path enter --network ns: takes.
nixcage_scope_netns() {
	local name="$1" status
	status="$(nixcage_scope_status "$name")" || return 1
	case "$status" in
	running\ *)
		local leader
		read -r _ leader _ <<<"$status"
		printf '%s/%s/ns/net\n' "$NIXCAGE_PROC" "$leader"
		;;
	*)
		echo "nixcage: $name is not running" >&2
		return 1
		;;
	esac
}

## Ends every process of the cage by stopping its scope.
nixcage_scope_stop() {
	local unit
	unit="$(nixcage_scope_unit "$1")" || {
		echo "nixcage: invalid container name: $1" >&2
		return 1
	}
	systemctl stop "$unit"
}

## A JSON string of a value the parse already held to an alphabet; the two
## characters JSON cannot take bare are escaped anyway, since a path is
## the one field whose alphabet is the filesystem's.
nixcage_scope_json_string() {
	local v="$1"
	v="${v//\\/\\\\}"
	v="${v//\"/\\\"}"
	v="${v//$'\n'/\\n}"
	v="${v//$'\t'/\\t}"
	printf '"%s"' "$v"
}

## nixcage_scope_record_write <name> <uid> <subject> <bridge> <address> <netns> [root...]
## One object on one line, so list --json can extend it without parsing it.
## A field the session was not given is absent rather than empty.
nixcage_scope_record_write() {
	local name="$1" uid="$2" subject="$3" bridge="$4" address="$5" netns="$6"
	shift 6
	nixcage_scope_name_ok "$name" || return 1
	local dir="$NIXCAGE_STATE_DIR/containers/$name" record root sep
	mkdir -p "$dir" || return 1
	record="{\"name\":$(nixcage_scope_json_string "$name"),\"uid\":$uid"
	[ -z "$subject" ] || record+=",\"subject\":$(nixcage_scope_json_string "$subject")"
	[ -z "$bridge" ] || record+=",\"bridge\":$(nixcage_scope_json_string "$bridge")"
	[ -z "$address" ] || record+=",\"address\":$(nixcage_scope_json_string "$address")"
	[ -z "$netns" ] || record+=",\"netns\":$(nixcage_scope_json_string "$netns")"
	if [ $# -gt 0 ]; then
		record+=',"roots":['
		sep=""
		for root in "$@"; do
			record+="$sep$(nixcage_scope_json_string "$root")"
			sep=","
		done
		record+=']'
	fi
	printf '%s}\n' "$record" >"$dir/placement"
}

## Every name under the state directory, one object per line: the record
## where there is one, the name alone where a cage was entered before
## records were kept, and the scope's cgroup and the leader's pid while
## the cage runs. The record is closed by its last byte, so the scope is
## spliced in before it.
nixcage_scope_list_json() {
	local containers="$NIXCAGE_STATE_DIR/containers" dir name record status leader cgroup
	[ -d "$containers" ] || return 0
	for dir in "$containers"/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		if [ -f "$dir/placement" ]; then
			record="$(<"$dir/placement")"
			record="${record%\}}"
		else
			record="{\"name\":$(nixcage_scope_json_string "$name")"
		fi
		status="$(nixcage_scope_status "$name" 2>/dev/null)" || status=stopped
		case "$status" in
		running\ *)
			read -r _ leader cgroup <<<"$status"
			record+=",\"scope\":$(nixcage_scope_json_string "$cgroup"),\"leader\":$leader"
			;;
		esac
		printf '%s}\n' "$record"
	done
}
