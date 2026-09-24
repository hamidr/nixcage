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
## systemd at hand (261 does the latter); vmspawn registers it under the
## name escaped as a unit name, a dash as \x2d, which for the alphabet
## check_name allows is the one character that changes (ADR-019). All
## three are asked, and the one that is active is the cage's; when none
## is, the registered nspawn spelling stands for what the name would be.
nixcage_scope_unit() {
	nixcage_scope_name_ok "$1" || return 1
	local unit escaped="machine-${1//-/\\x2d}.scope"
	[ "$escaped" != "machine-$1.scope" ] || escaped=""
	for unit in "$1.scope" $escaped; do
		if [ "$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)" = active ]; then
			printf '%s\n' "$unit"
			return 0
		fi
	done
	printf 'machine-%s.scope\n' "$1"
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

## The cage's first process: the one in the scope whose parent is nspawn,
## or vmspawn, whose one process in the scope is the VM (ADR-019). Older
## nspawn sits in the scope itself beside its child; systemd 261's stays
## outside and puts the cage under <scope>/payload/. Both places are read,
## the scope's own first; the spawner is known by its name, wherever it is.
nixcage_scope_leader() {
	local cgroup pid parent procs
	cgroup="$(nixcage_scope_cgroup "$1")" || return 1
	for procs in "$NIXCAGE_CGROUP_ROOT/$cgroup/cgroup.procs" "$NIXCAGE_CGROUP_ROOT/$cgroup/payload/cgroup.procs"; do
		[ -r "$procs" ] || continue
		while IFS= read -r pid; do
			[ -n "$pid" ] || continue
			parent="$(nixcage_scope_proc_field "$pid" PPid)"
			[ -n "$parent" ] || continue
			case "$(nixcage_scope_proc_field "$parent" Name)" in
			systemd-nspawn | systemd-vmspawn)
				printf '%s\n' "$pid"
				return 0
				;;
			esac
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
		## A microVM's leader is qemu, in the host's own namespace: there
		## is none to hand out, and the answer says so (ADR-019).
		if [ "$(nixcage_scope_record_substrate "$name")" = microvm ]; then
			echo none
			return 0
		fi
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

## nixcage_scope_record_write <name> <uid> <subject> <bridge> <address> <netns> <substrate> [--home=<path>] [--profile=<path>] [--writer=<path>] [--declared=<1|>] [--declared-bind=<arg>...] [root...]
## One object on one line, so list --json can extend it without parsing it.
## A field the session was not given is absent rather than empty; the
## substrate is absent for nspawn, which every cage ran on before ADR-019,
## so a record from before reads the same as one written now. The home is
## recorded when a caller named one, since exec on a microvm cage reads
## the session's group from it and the default is under the state
## directory only when nobody asked otherwise. The layer is recorded when
## a caller named one for the same reason: exec on a microvm cage sets PATH
## from it, and where nothing was declared it exists nowhere else.
##
## The writer and whether that session had a declaration are recorded where
## the caller names them (ADR-023 decision 4): one machine can hold cages
## written by a nixcage from the store and cages written by one a module
## installed, and a record that says which is a message rather than a puzzle.
## Absent where nobody names them, which is what every record held before.
nixcage_scope_record_write() {
	local name="$1" uid="$2" subject="$3" bridge="$4" address="$5" netns="$6" substrate="$7"
	shift 7
	nixcage_scope_name_ok "$name" || return 1
	local dir="$NIXCAGE_STATE_DIR/containers/$name" record root sep home="" profile=""
	local writer="" declared="" marked=""
	local -a roots=() declared_binds=()
	for root in "$@"; do
		case "$root" in
		--home=*) home="${root#--home=}" ;;
		--profile=*) profile="${root#--profile=}" ;;
		--writer=*) writer="${root#--writer=}" ;;
		--declared=*) declared="${root#--declared=}" marked=1 ;;
		--declared-bind=*) declared_binds+=("${root#--declared-bind=}") ;;
		*) roots+=("$root") ;;
		esac
	done
	mkdir -p "$dir" || return 1
	record="{\"name\":$(nixcage_scope_json_string "$name"),\"uid\":$uid"
	[ -z "$subject" ] || record+=",\"subject\":$(nixcage_scope_json_string "$subject")"
	[ -z "$bridge" ] || record+=",\"bridge\":$(nixcage_scope_json_string "$bridge")"
	[ -z "$address" ] || record+=",\"address\":$(nixcage_scope_json_string "$address")"
	[ -z "$netns" ] || record+=",\"netns\":$(nixcage_scope_json_string "$netns")"
	[ -z "$substrate" ] || [ "$substrate" = nspawn ] ||
		record+=",\"substrate\":$(nixcage_scope_json_string "$substrate")"
	[ -z "$home" ] || record+=",\"home\":$(nixcage_scope_json_string "$home")"
	[ -z "$profile" ] || record+=",\"profile\":$(nixcage_scope_json_string "$profile")"
	[ -z "$writer" ] || record+=",\"writer\":$(nixcage_scope_json_string "$writer")"
	if [ -n "$marked" ]; then
		if [ -n "$declared" ]; then
			record+=',"declared":true'
		else
			record+=',"declared":false'
		fi
	fi
	## What the host declared for this cage, which its caller did not ask
	## for: recorded apart from the roots so the two are distinguishable by
	## whoever reads the record rather than only by whoever wrote it.
	if [ "${#declared_binds[@]}" -gt 0 ]; then
		record+=',"declaredBinds":['
		sep=""
		for root in "${declared_binds[@]}"; do
			record+="$sep$(nixcage_scope_json_string "$root")"
			sep=","
		done
		record+=']'
	fi
	if [ "${#roots[@]}" -gt 0 ]; then
		record+=',"roots":['
		sep=""
		for root in "${roots[@]}"; do
			record+="$sep$(nixcage_scope_json_string "$root")"
			sep=","
		done
		record+=']'
	fi
	printf '%s}\n' "$record" >"$dir/placement"
}

## A path a cage's record names under <field>, empty when the session
## was not given one or there is no record; read by its own spelling as the
## substrate is.
nixcage_scope_record_path() {
	local record="$NIXCAGE_STATE_DIR/containers/$1/placement" field="$2"
	[ -f "$record" ] || return 0
	local line
	line="$(<"$record")"
	if [[ "$line" =~ \"$field\":\"([^\"]*)\" ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
}

## The home a cage's record names, empty for the default.
nixcage_scope_record_home() {
	nixcage_scope_record_path "$1" home
}

## The layer a cage's record names, empty where the host's was used.
nixcage_scope_record_profile() {
	nixcage_scope_record_path "$1" profile
}

## The substrate a cage's record fixed, empty for a cage with none or with
## no record: the one field enter reads back before it decides, so it is
## read by its own spelling rather than through a JSON parser the script
## does not carry.
nixcage_scope_record_substrate() {
	local record="$NIXCAGE_STATE_DIR/containers/$1/placement"
	[ -f "$record" ] || return 0
	local line
	line="$(<"$record")"
	if [[ "$line" =~ \"substrate\":\"([a-z]+)\" ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
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
