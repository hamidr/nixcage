# shellcheck shell=bash
## Guest-side devShell detection, sourced into the container session. Kept
## out of container.nix so it is a real shell file: shellcheck reads it and
## the bats suite sources it directly.

## Answer whether 'nix develop' has anything to enter in $1.
##
## Reading nix develop's own exit status cannot answer this: it fails
## identically for a flake with no devShell and a flake that does not
## evaluate, and quietly dropping a project with a broken flake into a bare
## shell would hide the breakage behind an environment that looks fine. So
## ask the flake instead, and report the two cases apart.
##
## The attribute list mirrors the one nix develop resolves, so a project that
## works today keeps working; only a project offering none of them falls back.
##
## Returns 0 when a devShell exists, 1 when the flake evaluates and offers
## none, and 2 when the flake itself failed to evaluate.
##
## A second argument names one devShell instead, which is how a specialist
## role gets its own toolchain: only that attribute is asked about, and the
## fallbacks a default-shell probe accepts do not apply, because a role that
## named a shell wants that shell and nothing else.
nixcage_has_dev_shell() {
	local project="${1:-/workspace}" want="${2:-}" answer test

	if [ -n "$want" ]; then
		nixcage_shell_name_ok "$want" || return 2
		test="shells ? \"${want}\""
	else
		test="shells ? default
      || legacy ? \${system}
      || packages ? default
      || legacyPackages ? \${system}"
	fi

	answer="$(nix eval --impure --raw --no-warn-dirty --expr "
    let
      flake = builtins.getFlake \"${project}\";
      system = builtins.currentSystem;
      shells = flake.devShells.\${system} or { };
      legacy = flake.devShell or { };
      packages = flake.packages.\${system} or { };
      legacyPackages = flake.defaultPackage or { };
    in
    if ${test}
    then \"yes\"
    else \"no\"
  ")" || return 2

	[ "$answer" = "yes" ]
}

## Answer whether $1 is spelled like a Nix attribute name nixcage will accept
## as a devShell. Narrower than Nix allows on purpose: the name reaches a
## flake reference and an eval expression, so anything that could be read as
## syntax there is refused where it is declared rather than where it breaks.
nixcage_shell_name_ok() {
	[[ "${1:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]
}

## The devShells the project offers, one per line. Only ever used to make a
## refusal useful: a role naming a shell that is not there needs to see what
## is, or the mistake is a typo hunt.
nixcage_dev_shell_names() {
	local project="${1:-/workspace}"
	nix eval --impure --raw --no-warn-dirty --expr "
    let
      flake = builtins.getFlake \"${project}\";
      shells = flake.devShells.\${builtins.currentSystem} or { };
    in
    builtins.concatStringsSep \"\\n\" (builtins.attrNames shells)
  " 2>/dev/null
}

## Enter the one devShell a role's declaration names.
##
## Refused rather than resolved when the project does not define it: falling
## back to the default shell would hand a specialist somebody else's tools and
## the run would fail somewhere far from the cause.
nixcage_enter_named_shell() {
	local project="$1" want="$2"
	shift 2

	if ! nixcage_shell_name_ok "$want"; then
		echo "nixcage: not a usable devShell name: $want" >&2
		return 1
	fi

	nixcage_has_dev_shell "$project" "$want"
	case $? in
	0) ;;
	1)
		{
			echo "nixcage: this role is declared to work in devShells.$want, which $project does not define; it offers:"
			## Indented in bash rather than with sed: this runs in the base
			## container userland, which carries a shell and nix and little
			## else, so a message must not depend on a text tool being there.
			## The list arrives without a trailing newline, so the last name
			## reaches the loop body only if the read's failure at EOF is
			## still treated as a line.
			local name
			while IFS= read -r name || [ -n "$name" ]; do
				[ -n "$name" ] || continue
				echo "  $name"
			done < <(nixcage_dev_shell_names "$project")
		} >&2
		return 1
		;;
	*)
		echo "nixcage: the project flake failed to evaluate; see the error above" >&2
		return 1
		;;
	esac

	if [ "$#" -gt 0 ]; then
		exec nix develop "$project#$want" --command "$@"
	fi
	exec nix develop "$project#$want"
}

## Enter the project's environment, choosing it by what the project offers.
## Any arguments are the command to run non-interactively.
##
## A project with no devShell gets the container's base userland rather than
## a refusal: the container is the point, and not every project under a
## workspace root defines a shell. The fallback is announced, and a flake
## that failed to evaluate is never given one -- that is a defect to fix, not
## an environment to substitute.
## Point direnv at nix-direnv's stdlib, which caches the devShell profile and
## keeps a gcroot on it. Without it every entry re-evaluates the flake and the
## VM's weekly collection drops the closure between sessions. The home is
## persistent, so this is written once and then confirmed cheaply.
nixcage_seed_direnvrc() {
	local rc="$HOME/.config/direnv/direnvrc" line="source $NIXCAGE_DIRENVRC"
	[ -n "${NIXCAGE_DIRENVRC:-}" ] || return 0
	## Matched in bash rather than with grep: the base container userland is a
	## shell, nix, git and little else, and a missing grep here would report
	## the line absent every time and append it on every session.
	if [ -f "$rc" ]; then
		local existing
		while IFS= read -r existing || [ -n "$existing" ]; do
			[ "$existing" = "$line" ] && return 0
		done <"$rc"
	fi
	mkdir -p "$(dirname "$rc")"
	echo "$line" >>"$rc"
}

## Enter the project through its own .envrc, as the host shell would.
##
## direnv refuses an .envrc it has not been told to trust, and there is nobody
## to ask inside a container. Granting it here is the same bargain the
## container itself makes: the session was opened on this project deliberately,
## and the .envrc can reach nothing the session could not already reach.
nixcage_enter_direnv() {
	local project="$1"
	shift
	nixcage_seed_direnvrc
	direnv allow "$project"
	if [ "$#" -gt 0 ]; then
		exec direnv exec "$project" "$@"
	fi
	exec direnv exec "$project" bash
}

nixcage_enter_shell() {
	local project="${NIXCAGE_PROJECT:-/workspace}"

	## A role that named its own devShell has said what its environment is more
	## specifically than the project can, so it wins over both the .envrc and
	## the default-shell probe. Several specialists work one repository, and an
	## .envrc offers them all one environment.
	if [ -n "${NIXCAGE_SHELL:-}" ]; then
		nixcage_enter_named_shell "$project" "$NIXCAGE_SHELL" "$@"
		return
	fi

	## An .envrc is the project saying what its environment is, so it wins over
	## the devShell probe -- which is usually the same answer, since most of
	## these files are one 'use flake' line.
	if [ -f "$project/.envrc" ]; then
		nixcage_enter_direnv "$project" "$@"
		return
	fi

	nixcage_has_dev_shell "$project"
	case $? in
	0)
		if [ "$#" -gt 0 ]; then
			exec nix develop --command "$@"
		fi
		exec nix develop
		;;
	1)
		echo "nixcage: no devShell in this project; entering the base container shell" >&2
		if [ "$#" -gt 0 ]; then
			exec "$@"
		fi
		exec bash
		;;
	*)
		echo "nixcage: the project flake failed to evaluate; see the error above" >&2
		return 1
		;;
	esac
}
