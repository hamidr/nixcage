# shellcheck shell=bash
## What a cage may use (ADR-022): a memory size and a count of cpus, rendered
## by each substrate with the strongest thing it has -- MemoryMax= and
## CPUQuota= on an nspawn cage's scope, the guest's own RAM and vCPUs on a
## microVM.
##
## In precedence: the flag, the host's declaration for this cage, the host's
## default. A declaration is a default and not a ceiling, so nothing here
## refuses: a caller of the exported interface already runs privileged where
## the cages are, and a bound it can raise carries no security claim. The
## boundary a cage has is its substrate.
##
## Nothing is recorded. A size is not a cage's nature the way its substrate
## is, so it is resolved again at every enter and a host that lowers its
## declaration reaches every cage at the next one.
##
## Sourced by store path into nixcage-container.

## nixcage_bounds_declared <project> <declarations>
## The bounds the host declared for a project path, from the lines it
## rendered (one "<path> <memory> <cpus>" per line, "-" where it said nothing
## about one of them), or nothing. The path is matched whole: a declaration
## for a directory says nothing about the directories under it, which are
## other cages.
nixcage_bounds_declared() {
	local project="$1" declarations="$2" path memory cpus
	while read -r path memory cpus; do
		if [ "$path" = "$project" ]; then
			echo "$memory $cpus"
			return 0
		fi
	done <<<"$declarations"
}

## nixcage_bounds_field <1|2> <declaration>
## One quantity of a declaration: the memory or the cpus. A "-" is the
## spelling of "the host said nothing about this one", so it reads as empty
## rather than reaching a flag's grammar as a value.
nixcage_bounds_field() {
	## Split in bash rather than with cut: this runs beside substrate.sh in
	## nixcage-container, which reaches for no text tool to read a line the
	## host module wrote.
	local field="$1" declaration="$2" memory cpus word
	read -r memory cpus <<<"$declaration"
	case "$field" in
	1) word="$memory" ;;
	2) word="$cpus" ;;
	*) return 1 ;;
	esac
	[ "$word" = - ] || echo "$word"
}

## nixcage_bounds_resolve <flag> <declared> <default>
## One quantity, from the closest source that has one. Empty means the
## substrate's own default, which nixcage does not choose: unbounded on
## nspawn, and whatever systemd-vmspawn boots with on a microVM.
nixcage_bounds_resolve() {
	local flag="$1" declared="$2" default="$3" word
	for word in "$flag" "$declared" "$default"; do
		if [ -n "$word" ] && [ "$word" != - ]; then
			echo "$word"
			return 0
		fi
	done
}

## nixcage_bounds_machine [proc]
## Half of what this machine has, in the spellings systemd takes. Undeclared
## there is no host to say what a cage may use and no module to guess in
## (ADR-023 decision 10), and without this the first microVM anybody boots
## gets systemd-vmspawn's 2 GiB and one vCPU, which is the cage ADR-022 exists
## to stop handing out. A flag and a declaration both still outrank it.
##
## A machine that cannot be read is said nothing about rather than guessed at,
## and the substrate's own default is then what the session gets.
nixcage_bounds_machine() {
	local proc="${1:-/proc}" kb cpus
	[ -r "$proc/meminfo" ] && [ -r "$proc/cpuinfo" ] || return 0
	while read -r field value _; do
		if [ "$field" = "MemTotal:" ]; then
			kb="$value"
			break
		fi
	done <"$proc/meminfo"
	[ -n "${kb:-}" ] || return 0
	cpus=0
	while read -r field _; do
		if [ "$field" = "processor" ]; then
			cpus=$((cpus + 1))
		fi
	done <"$proc/cpuinfo"
	if [ "$cpus" -gt 1 ]; then
		cpus=$((cpus / 2))
	fi
	[ "$cpus" -gt 0 ] || return 0
	echo "$((kb / 2048))M $cpus"
}
