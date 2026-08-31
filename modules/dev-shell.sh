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
nixcage_enter_shell() {
	nixcage_has_dev_shell /workspace
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
		echo "nixcage: the flake in /workspace failed to evaluate; see the error above" >&2
		return 1
		;;
	esac
}
