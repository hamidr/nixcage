#!/usr/bin/env bash
# What a host declared about nixcage, and what stands in for it where nothing
# was declared. A shell file rather than an inline string so shellcheck reads
# it and the suite sources it.

## Read the declaration a host rendered, or give the undeclared answer to it.
## One reader with two implementations: an option added later has one place to
## say what it means where nothing was declared, instead of a file test
## spreading through every verb that consults one.
##
## NIXCAGE_DECLARED says which implementation answered, because some verbs owe
## a caller a refusal rather than a default. It is read by those verbs, which
## shellcheck cannot see from inside this file.
## nixcage_declaration_read <config>
# shellcheck disable=SC2034
nixcage_declaration_read() {
	local config="$1"
	NIXCAGE_DECLARED=""
	[ -f "$config" ] || return 0
	NIXCAGE_DECLARED=1
	# shellcheck disable=SC1090
	. "$config"
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
