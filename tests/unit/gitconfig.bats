#!/usr/bin/env bats
# The identity a session commits as, rendered where the session is rather than
# by the module that declared it (ADR-024). One renderer, so a declared host
# and a host that declared nothing produce the same file from the same fields.

load ../test_helper/common

setup() {
	# shellcheck source=../../modules/gitconfig.sh
	source "$NIXCAGE_ROOT/modules/gitconfig.sh"
}

@test "an identity is a user section and nothing else when signing is off" {
	run nixcage_gitconfig_text "Ada Lovelace" ada@example.org "" /nix/store/x/bin/ssh-keygen
	assert_success
	assert_line "[user]"
	assert_line "  name = Ada Lovelace"
	assert_line "  email = ada@example.org"
	refute_line --partial gpgsign
}

# Signing goes through the invoking user's agent: the key is asked of the
# agent at commit time and no key material is in the cage (ADR-008).
@test "signing names the agent's first key and the keygen that asks for it" {
	run nixcage_gitconfig_text Ada ada@example.org 1 /nix/store/x/bin/ssh-keygen
	assert_success
	assert_line "  format = ssh"
	assert_line "  program = /nix/store/x/bin/ssh-keygen"
	assert_line "  defaultKeyCommand = ssh-add -L"
	assert_line "  gpgsign = true"
}

@test "a field nobody named is left out rather than written empty" {
	run nixcage_gitconfig_text "" ada@example.org "" /nix/store/x/bin/ssh-keygen
	assert_success
	assert_line "  email = ada@example.org"
	refute_line --partial "name ="
}

# Nothing at all is not a file: git's own "who are you" is a better error
# than an identity that is half there.
@test "an identity nobody named at all renders nothing" {
	run nixcage_gitconfig_text "" "" 1 /nix/store/x/bin/ssh-keygen
	assert_success
	[ "$output" = "" ]
}
