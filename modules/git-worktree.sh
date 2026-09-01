# shellcheck shell=bash
## Git directory resolution for a session's project, sourced by
## nixcage-container before it builds the nspawn command line. Kept out of
## container.nix so it is a real shell file: shellcheck reads it and the bats
## suite sources it directly.

## Collapse '.', '..' and repeated slashes out of an absolute path without
## touching the filesystem. Git resolves the pointers below textually against
## paths it wrote itself, so the bind must land on the same spelling git will
## open rather than on a symlink-resolved twin of it.
nixcage_lexical_path() {
	local path="$1" part out=""
	local IFS=/
	for part in $path; do
		case "$part" in
		"" | .) ;;
		..) out="${out%/*}" ;;
		*) out="$out/$part" ;;
		esac
	done
	printf '%s\n' "${out:-/}"
}

## Print the git directories that must be bound into the container in
## addition to the project itself, one per line.
##
## An ordinary repository keeps everything in $project/.git, which the project
## bind already covers. A linked worktree does not: its .git is a file holding
## an absolute pointer into the primary repository, and its object store and
## refs live further up still. Bind only the project and git inside the
## container reports 'fatal: not a git repository: (null)'.
##
## Two directories are involved. The administrative directory named by the
## pointer holds this worktree's HEAD and index; the common directory it names
## in turn holds the objects and refs shared with every other worktree. The
## administrative directory usually sits inside the common one, in which case
## a single bind covers both.
##
## Returns non-zero when the project claims to be a worktree but the pointer
## does not lead anywhere: entering with a silently broken git is worse than
## refusing.
nixcage_git_binds() {
	local project="${1:?}" dotgit
	dotgit="$1/.git"

	## Absent: not a repository. A directory: an ordinary repository, already
	## inside the project bind.
	[ -f "$dotgit" ] || return 0

	local line admin common
	line="$(head -n 1 "$dotgit")"
	case "$line" in
	"gitdir: "*) admin="${line#gitdir: }" ;;
	*)
		echo "nixcage: $dotgit is not a git worktree pointer" >&2
		return 1
		;;
	esac

	## Trailing whitespace would otherwise become part of the path.
	admin="${admin%"${admin##*[![:space:]]}"}"
	case "$admin" in
	/*) ;;
	*) admin="$project/$admin" ;;
	esac
	admin="$(nixcage_lexical_path "$admin")"
	if [ ! -d "$admin" ]; then
		echo "nixcage: worktree git directory not found: $admin" >&2
		return 1
	fi

	common="$admin"
	if [ -f "$admin/commondir" ]; then
		common="$(head -n 1 "$admin/commondir")"
		case "$common" in
		/*) ;;
		*) common="$admin/$common" ;;
		esac
		common="$(nixcage_lexical_path "$common")"
		if [ ! -d "$common" ]; then
			echo "nixcage: shared git directory not found: $common" >&2
			return 1
		fi
	fi

	## One bind when the administrative directory is inside the common one,
	## which is how git lays a worktree out by default.
	if [ "$admin" = "$common" ] || [ "${admin#"$common"/}" != "$admin" ]; then
		printf '%s\n' "$common"
	elif [ "${common#"$admin"/}" != "$common" ]; then
		printf '%s\n' "$admin"
	else
		printf '%s\n%s\n' "$common" "$admin"
	fi
}
