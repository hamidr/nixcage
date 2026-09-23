#!/usr/bin/env bash
# The identity a session commits as, rendered where the session is.
#
# A host declares it and a caller may name it, and both arrive here as the
# same three fields, so a declared host and a host that declared nothing get
# one file from one renderer rather than two that drift.
#
# Signing goes through the invoking user's ssh-agent: git is told to ask the
# agent for its first key at commit time, which is why no key material is in
# a cage and why this file names a program rather than a key.

## nixcage_gitconfig_text <name> <email> <signing> <ssh-keygen>
## The file, or nothing where neither field was named: git's own "who are
## you" is a better error than an identity that is half there.
nixcage_gitconfig_text() {
	local name="$1" email="$2" signing="$3" keygen="$4"
	[ -n "$name" ] || [ -n "$email" ] || return 0
	echo "[user]"
	[ -z "$name" ] || echo "  name = $name"
	[ -z "$email" ] || echo "  email = $email"
	[ -n "$signing" ] || return 0
	cat <<GITCONFIG
[gpg]
  format = ssh
[gpg "ssh"]
  program = $keygen
  defaultKeyCommand = ssh-add -L
[commit]
  gpgsign = true
[tag]
  gpgsign = true
GITCONFIG
}
