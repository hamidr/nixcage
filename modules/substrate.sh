# shellcheck shell=bash
## Which substrate a cage runs on (ADR-019): nspawn, one kernel shared with
## the host, or microvm, a kernel of its own under systemd-vmspawn.
##
## The choice is made when the cage is defined and then fixed, because the
## two substrates keep different things (a home written through virtiofs as
## the host uid, a disk image, a record with a substrate field) and a cage
## that flips between them meets its own files as a stranger. In precedence:
## the host's declaration for the cage, the record of its first enter, the
## flag, the host's default. A flag that loses to a declaration or a record
## is refused rather than overridden, naming what won and where it came
## from, so the caller learns the cage's nature at the flag and not from a
## session that behaves unlike the one asked for.
##
## Sourced by store path into nixcage-container.

nixcage_substrate_word_ok() {
	case "$1" in
	nspawn | microvm) return 0 ;;
	*) return 1 ;;
	esac
}

## nixcage_substrate_resolve <name> <declared> <recorded> <flag> <default>
## Prints the substrate. Every input may be empty; the default of the default
## is nspawn, the substrate every cage ran on before ADR-019.
nixcage_substrate_resolve() {
	local name="$1" declared="$2" recorded="$3" flag="$4" default="$5"
	local word
	for word in "$declared" "$recorded" "$flag" "$default"; do
		if [ -n "$word" ] && ! nixcage_substrate_word_ok "$word"; then
			echo "nixcage: not a substrate: $word" >&2
			return 1
		fi
	done

	local fixed="" source=""
	if [ -n "$declared" ]; then
		fixed="$declared" source="the host's declaration"
	elif [ -n "$recorded" ]; then
		fixed="$recorded" source="its record"
	fi
	if [ -n "$fixed" ]; then
		if [ -n "$flag" ] && [ "$flag" != "$fixed" ]; then
			echo "nixcage: $name runs on $fixed by $source; --substrate $flag refused" >&2
			return 1
		fi
		echo "$fixed"
		return 0
	fi
	echo "${flag:-${default:-nspawn}}"
}
