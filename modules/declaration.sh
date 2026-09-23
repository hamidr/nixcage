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
