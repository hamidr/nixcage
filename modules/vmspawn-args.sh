# shellcheck shell=bash
## The vmspawn line a microvm session runs (ADR-019).
##
## A second assembler from the parse enter-args.sh produces, beside the
## nspawn one: the same binds, the same name, the same bounds, spelt for
## systemd-vmspawn. What nspawn takes as a command and an environment,
## vmspawn cannot: it boots an init. So both go into one credential the
## guest's session unit reads, and the line here carries the credential's
## path and nothing of what the session runs.
##
## Sourced by store path into nixcage-container, after scope.sh, whose JSON
## string spelling the credential is written with.

## What the SMBIOS path carries. Measured on systemd 261 and qemu 10.2: a
## 48000-byte credential reaches the guest beside what vmspawn adds of its
## own (the ssh key, its unit dropin, the mounts), a 49000-byte one takes
## every credential down with it, silently. One type 11 structure holds
## them all under 64 KiB base64-encoded; this constant leaves the rest to
## vmspawn's own and their growth.
NIXCAGE_VMSPAWN_CREDENTIAL_MAX=32768

## nixcage_vmspawn_credential <uid> <gid> <home> <cwd> <tty> <address> <agent> <dns> [--setenv=K=V...] -- <argv...>
## One JSON object, one line: who argv runs as, where, with what
## environment, on a tty or captured, the address to set when the session
## was placed and what it resolves with there (ADR-016), and whether an
## agent socket is on its way, so the guest waits for it before argv
## runs. The environment words are the parse's own, so a caller hands
## them over unchanged.
nixcage_vmspawn_credential() {
	local uid="$1" gid="$2" home="$3" cwd="$4" tty="$5" address="$6" agent="$7" dns="$8"
	shift 8
	local cred sep="" word
	cred="{\"uid\":$uid,\"gid\":$gid"
	cred+=",\"home\":$(nixcage_scope_json_string "$home")"
	cred+=",\"cwd\":$(nixcage_scope_json_string "$cwd")"
	cred+=",\"tty\":$([ "$tty" = 1 ] && echo true || echo false)"
	[ -z "$address" ] || cred+=",\"address\":$(nixcage_scope_json_string "$address")"
	cred+=",\"agent\":$([ -n "$agent" ] && echo true || echo false)"
	[ -z "$dns" ] || cred+=",\"dns\":$(nixcage_scope_json_string "$dns")"
	cred+=',"env":{'
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		word="${1#--setenv=}"
		cred+="$sep$(nixcage_scope_json_string "${word%%=*}"):$(nixcage_scope_json_string "${word#*=}")"
		sep=","
		shift
	done
	shift || true
	cred+='},"argv":['
	sep=""
	for word in "$@"; do
		cred+="$sep$(nixcage_scope_json_string "$word")"
		sep=","
	done
	printf '%s]}\n' "$cred"
}

## Refused before boot rather than lost in it: over the bound, vmspawn
## and the guest say nothing and the session unit never gets its argv.
nixcage_vmspawn_credential_ok() {
	local size=${#1}
	if [ "$size" -gt "$NIXCAGE_VMSPAWN_CREDENTIAL_MAX" ]; then
		echo "nixcage: session credential is $size bytes; the SMBIOS path carries $NIXCAGE_VMSPAWN_CREDENTIAL_MAX" >&2
		return 1
	fi
}

## nixcage_vmspawn_args <name> <skeleton> <toplevel> <credential> <uid> <block> <tty> <memory> <cpus> <disk> <qemu extra> [bind words...]
## The line as it would run, one word per line, from the environment word
## on: vmspawn writes its own -append and has no flag to extend it, so
## init= reaches the kernel by repeating its three words through the qemu
## extra, and qemu keeps the last -append. The guest's own kernel
## parameters never reach it this way, so net.ifnames=0 is repeated here:
## the session unit names the one interface eth0. The console is the session's
## output: the kernel is told to print nothing on it from the start (the
## guest pins that level again by sysctl, since something in its boot
## raises it back to 4), systemd to show no status on it and to log
## nowhere, since a shutdown that logs to kmsg raises the level to
## warnings and the power-down line would end every captured session;
## and its init is told the console is dumb, or it would reset the
## terminal and mark the boot with OSC sequences. argv's own TERM comes
## from the credential. A placed session's tap goes to qemu through the
## same words (veth.sh), since vmspawn's own tap would carry its name and
## the host's networkd rules rather than nixcage's. The skeleton is the
## root share,
## shifted onto the cage's block so guest root's writes into it land there;
## every other share is the host uid unshifted (decision 5). Registered so
## machined records the address and key exec reaches the guest with.
nixcage_vmspawn_args() {
	local name="$1" skeleton="$2" toplevel="$3" credential="$4"
	local uid="$5" block="$6" tty="$7" memory="$8" cpus="$9" disk="${10}" extra="${11}"
	shift 11
	printf '%s\n' env \
		"SYSTEMD_VMSPAWN_QEMU_EXTRA=-append 'root=root rootfstype=virtiofs rw init=$toplevel/init console=hvc0 net.ifnames=0 loglevel=0 systemd.show_status=0 systemd.log_target=null TERM=dumb'${extra:+ $extra}" \
		systemd-vmspawn \
		--quiet --register=yes \
		"--machine=$name" \
		"--directory=$skeleton" \
		"--linux=$toplevel/kernel" \
		"--initrd=$toplevel/initrd" \
		--firmware=none \
		"--private-users=$uid:$block" \
		"--console=$([ "$tty" = 1 ] && echo interactive || echo read-only)"
	[ -z "$memory" ] || printf -- '--ram=%s\n' "$memory"
	[ -z "$cpus" ] || printf -- '--cpus=%s\n' "$cpus"
	printf -- '--load-credential=nixcage.session:%s\n' "$credential"
	[ -z "$disk" ] || printf -- '--extra-drive=%s\n' "$disk"
	printf '%s\n' --bind-ro=/nix/store "$@"
}
