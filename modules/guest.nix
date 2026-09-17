## The guest a microvm session boots (ADR-019): one NixOS system per host,
## built by the host module from the host's own pkgs so its systemd is the
## one the host's vmspawn expects, and carrying one unit of nixcage's.
##
## Its root is the skeleton vmspawn exports over virtiofs, and everything a
## boot writes goes to tmpfs that dies with the session. The store is a
## read-only share the initrd mounts before it looks for the closure.
## Credentials arrive as SMBIOS strings, which the NixOS kernel exposes only
## once dmi_sysfs is loaded, so the initrd loads it. There is no nix daemon
## and no way to build: decision 4.
{
  lib,
  pkgs,
  ...
}:
let
  ## The unit's script: the shell file the suite reads, sourced by store
  ## path, with the tools it names on its path.
  session = pkgs.writeShellApplication {
    name = "nixcage-session";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      iproute2
      util-linux
      e2fsprogs
      systemd
    ];
    excludeShellChecks = [ "SC1091" ];
    text = ''
      . ${./guest-session.sh}
      nixcage_session_main
    '';
  };
  ## vmspawn's dropin for the vsock sshd names systemd-tmpfiles and sshd
  ## bare, which this systemd does not find on its search path: as a dropin
  ## sorting after 50-credential.conf, its ExecStartPre is cleared and done
  ## again with store paths, plus a host key, since /etc is empty at boot.
  sshdPre = pkgs.writeShellScript "nixcage-sshd-vsock-pre" ''
    mkdir -p /etc/ssh "/run/sshd-vsock-$1"
    cat "$CREDENTIALS_DIRECTORY/ssh.ephemeral-authorized_keys-all" >"/run/sshd-vsock-$1/authorized_keys"
    [ -f /etc/ssh/ssh_host_ed25519_key ] ||
      ${pkgs.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f /etc/ssh/ssh_host_ed25519_key
  '';
in
{
  networking.hostName = "nixcage-guest";
  networking.useDHCP = false;
  ## The one interface a placed guest has is the tap, named eth0 so the
  ## session unit can give it the address without asking which it is.
  ## This renders net.ifnames=0 into kernel parameters the direct boot
  ## never reads; the assembler repeats it on the command line it writes.
  networking.usePredictableInterfaceNames = false;
  system.stateVersion = lib.mkDefault "25.11";
  documentation.enable = false;
  nix.enable = false;
  boot.loader.grub.enable = false;

  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [
    "virtiofs"
    "virtio_pci"
    "virtio_console"
    "virtio_blk"
    "fuse"
    "vmw_vsock_virtio_transport"
    "vsock"
    "dmi_sysfs"
  ];
  boot.initrd.kernelModules = [
    "virtiofs"
    "virtio_console"
    "dmi_sysfs"
  ];
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];
  ## The console is the session's output; the kernel says nothing on it,
  ## not even the power-down line. loglevel=0 on the command line holds
  ## through the initrd and is raised back to 4 by something in stage 2;
  ## this pins it again. A panic raises the level itself.
  boot.kernel.sysctl."kernel.printk" = "0 4 1 7";

  fileSystems."/" = {
    device = "root";
    fsType = "virtiofs";
  };
  fileSystems."/etc" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };
  fileSystems."/var" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };
  fileSystems."/tmp" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=1777" ];
  };

  ## The console is the session's; a getty on it would type over argv.
  systemd.services."serial-getty@hvc0".enable = false;

  ## exec reaches the guest over vsock ssh with the key vmspawn made; no
  ## password, no key of nixcage's, no port on any network.
  services.openssh.enable = true;
  services.openssh.startWhenNeeded = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  services.openssh.settings.PasswordAuthentication = false;
  ## The host's agent arrives as a remote socket forward to
  ## /run/ssh-agent.sock, made by sshd as root: open to every uid in the
  ## guest, which is the one session, as the nspawn bind is to its uid.
  services.openssh.settings.StreamLocalBindMask = "0000";
  services.openssh.settings.StreamLocalBindUnlink = "yes";
  services.openssh.hostKeys = [ ];
  systemd.services."sshd-vsock@" = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStartPre = [
      ""
      "+${sshdPre} %i"
    ];
    serviceConfig.ExecStart = [
      ""
      "-${pkgs.openssh}/bin/sshd -i -o 'AuthorizedKeysFile=/run/sshd-vsock-%i/authorized_keys .ssh/authorized_keys'"
    ];
  };

  ## Started as part of boot, so vmspawn's READY=1 is the moment argv runs;
  ## on the console, as the controlling tty, so an interactive session is
  ## one. The unit ends the guest itself.
  systemd.services.nixcage-session = {
    description = "nixcage session";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "network-pre.target"
    ];
    serviceConfig = {
      Type = "simple";
      LoadCredential = "nixcage.session";
      ExecStart = "${session}/bin/nixcage-session";
      StandardInput = "tty-force";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/hvc0";
      ## No reset, and a terminal named so it is not asked its name: both
      ## write sequences a captured session would carry home. The kernel
      ## command line names the console dumb to its init for the same
      ## reason; argv's own TERM comes from the credential.
      TTYReset = false;
      TTYVHangup = true;
      Environment = "TERM=dumb";
    };
  };
}
