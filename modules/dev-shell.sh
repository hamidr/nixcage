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
nixcage_has_dev_shell() {
	local project="${1:-/workspace}" answer

	answer="$(nix eval --impure --raw --no-warn-dirty --expr "
    let
      flake = builtins.getFlake \"${project}\";
      system = builtins.currentSystem;
      shells = flake.devShells.\${system} or { };
      legacy = flake.devShell or { };
      packages = flake.packages.\${system} or { };
      legacyPackages = flake.defaultPackage or { };
    in
    if shells ? default
      || legacy ? \${system}
      || packages ? default
      || legacyPackages ? \${system}
    then \"yes\"
    else \"no\"
  ")" || return 2

	[ "$answer" = "yes" ]
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
	if [ ! -f "$rc" ] || ! grep -qF "$line" "$rc"; then
		mkdir -p "$(dirname "$rc")"
		echo "$line" >>"$rc"
	fi
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
