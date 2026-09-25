## The guest a machine boots (ADR-026): the session guest's boot, with no
## session in it and nixcage's host module beside it, so it is a nixcage
## host that stays up. Imported by the host module with guest.nix and
## host.nix; a dependant's own modules come after it.
##
## What it writes is kept on its disk, the raw image the host hands qemu
## and never reads: nixcage's state and every cage's home. Everything else
## of the guest is the tmpfs the session guest already has, rebuilt at each
## boot from the store.
{ lib, ... }:
{
  ## The session unit ends the guest when argv ends; a machine has none.
  systemd.services.nixcage-session.enable = lib.mkForce false;

  ## Formatted on first boot, the only filesystem the guest keeps. ext4
  ## rather than ZFS, so no pool is on a device a host could import.
  fileSystems."/var/lib/nixcage" = {
    device = "/dev/vda";
    fsType = "ext4";
    autoFormat = true;
  };

  ## A machine's cages are reached by forward, not by a person entering a
  ## project, so it declares no workspace roots unless a dependant does.
  nixcage.workspaceRoots = lib.mkDefault [ ];

  ## Declared, so storage ensure refuses a quota the disk would make a lie.
  nixcage.machineGuest = true;

  ## A machine's console is read into its unit's journal on the host, so
  ## its kernel may speak there as any host's does.
  boot.kernel.sysctl."kernel.printk" = lib.mkForce "4 4 1 7";
}
