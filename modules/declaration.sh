#!/usr/bin/env bash
# What a host declared about nixcage, and what stands in for it where nothing
# was declared. A shell file rather than an inline string so shellcheck reads
# it and the suite sources it.

## What this nixcage renders and can read. A host and the nixcage standing on
## it are one repository but not one installation, so the two can differ.
NIXCAGE_DECLARATION_VERSION=1

## Every setting a declaration carries, at the value it has where nothing was
## declared. This list is the one place an option states that value, and the
## reason a reader states them all before reading anything: a key the current
## host omits must not be answered by the last host that was read.
# shellcheck disable=SC2034
nixcage_declaration_reset() {
	NIXCAGE_DECLARED=""
	NIXCAGE_DECLARATION_LEGACY=""
	DECLARATION_VERSION=""
	WORKSPACE_ROOTS=""
	PRINCIPAL_UID_BASE=""
	PRINCIPAL_UID_SIZE=""
	PRINCIPAL_SUBJECTS=""
	STORAGE_DATASET=""
	HOST_PLATFORM=""
	SUBSTRATE_DEFAULT=""
	CAGE_SUBSTRATES=""
	BOUNDS_DEFAULT=""
	CAGE_BOUNDS=""
	MICROVM_GUEST=""
	SECRET_ENV=""
	GIT_USER_NAME=""
	GIT_USER_EMAIL=""
	GIT_SIGNING=""
	## Set in a machine's guest (ADR-026), where a quota is refused.
	MACHINE_GUEST=""
}

## Read the declaration a host rendered, or give the undeclared answer to it.
## One reader with two implementations: an option added later has one place to
## say what it means where nothing was declared, instead of a file test
## spreading through every verb that consults one.
##
## NIXCAGE_DECLARED says which implementation answered, because some verbs owe
## a caller a refusal rather than a default. It and the settings are read by
## those verbs, which shellcheck cannot see from inside this file.
##
## Answers 2 for a declaration this nixcage cannot read. A host that declared
## workspace roots must never read as a host that declared nothing, which is
## what a version-blind reader would do the first time the format changes.
## nixcage_declaration_read <declaration>
# shellcheck disable=SC2034
nixcage_declaration_read() {
	local declaration="$1"
	nixcage_declaration_reset
	[ -f "$declaration" ] || return 0
	# shellcheck disable=SC1090
	. "$declaration"
	if [ "${DECLARATION_VERSION:-}" != "$NIXCAGE_DECLARATION_VERSION" ]; then
		echo "nixcage: $declaration is version ${DECLARATION_VERSION:-none} and this nixcage reads $NIXCAGE_DECLARATION_VERSION" >&2
		echo "nixcage: apply the matching nixcage in your configuration, or install the one it renders for" >&2
		nixcage_declaration_reset
		return 2
	fi
	NIXCAGE_DECLARED=1
}

## The files a nixcage before ADR-024 rendered, translated into the keys this
## one reads. One function rather than a second set of call sites, and deleted
## one release after the declaration lands: a CLI installed on its own can
## stand on a module older than itself, and reading nothing there would make a
## host with workspace roots answer as a host with none.
## nixcage_declaration_read_legacy <config> <container>
# shellcheck disable=SC2034
nixcage_declaration_read_legacy() {
	local config="$1" container="$2" key value
	nixcage_declaration_reset
	[ -f "$config" ] || [ -f "$container" ] || return 0
	if [ -f "$container" ]; then
		# shellcheck disable=SC1090
		. "$container"
	fi
	if [ -f "$config" ]; then
		while IFS='=' read -r key value || [ -n "$key" ]; do
			case "$key" in
			WORKSPACE_ROOTS) WORKSPACE_ROOTS="$value" ;;
			esac
		done <"$config"
	fi
	NIXCAGE_DECLARED=1
	NIXCAGE_DECLARATION_LEGACY=1
}

## The variable and secret pairs a declaration names, one per line. A word
## list rather than a file of its own: a secret's name is an attribute name
## and a variable's name is checked as one, so neither holds a space.
nixcage_declaration_secret_pairs() {
	local pair
	for pair in ${SECRET_ENV:-}; do
		printf '%s\n' "$pair"
	done
}

## What a verb says when what it needs is something only a host can declare.
## The option is named rather than described, so a caller reads the refusal
## and knows the line to write.
## nixcage_declaration_refusal <verb> <option>
nixcage_declaration_refusal() {
	printf '%s needs %s: import nixcage nixosModules.host and set it' "$1" "$2"
}

## nixcage_declaration_carried_flag <declared> <profile> <guest> <microvm paths>
## The first of the flags naming what a session is built from that a declared
## host may not be given, or nothing.
##
## ADR-009 lets a caller widen a session because that caller already runs as
## root outside every cage. Where an administrator grants nixcage-container
## through sudoers and nothing else, that is not so, and these three flags
## would let the caller choose the userland a root session is built from and
## the toplevel vmspawn boots. A host that declared its own answer keeps it.
nixcage_declaration_carried_flag() {
	local declared="$1" profile="$2" guest="$3" paths="$4"
	[ -n "$declared" ] || return 0
	if [ -n "$profile" ]; then
		echo --profile
	elif [ -n "$guest" ]; then
		echo --guest
	elif [ "$paths" -gt 0 ]; then
		echo --microvm-path
	fi
}
