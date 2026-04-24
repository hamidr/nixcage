## Base NixOS module applied to every nixcage VM.
## Users extend the VM via their project-local nixcage.vm.nix, not here.
{ pkgs, lib, ... }:
{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages =
    with pkgs;
    [
      claude-code
      git
      nodejs_22
      jq
      curl
      bash
      openssh
    ]
    ## opencode is relatively new; skip gracefully if nixpkgs doesn't carry it yet
    ++ lib.optionals (pkgs ? opencode) [ pkgs.opencode ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.nixcage = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
    ## The authorized key is injected by the per-project generated flake so
    ## each collaborator's key can differ without touching this shared module.
  };

  security.sudo.wheelNeedsPassword = false;

  fileSystems."/workspace" = {
    device = "workspace";
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  ## Copies /run/nixcage-secrets (piped in by 'nixcage start') into
  ## /etc/profile.d/ so every login shell picks up the API keys.
  ## /run is tmpfs -- secrets never reach disk.
  systemd.services.nixcage-secrets = {
    description = "Install nixcage secrets into login-shell environment";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ -f /run/nixcage-secrets ]; then
        cp /run/nixcage-secrets /etc/profile.d/nixcage-secrets.sh
        chmod 600 /etc/profile.d/nixcage-secrets.sh
      fi
    '';
  };

  ## Drop the user into /workspace on SSH login when their shell starts in $HOME.
  ## This makes 'nixcage shell' feel like a normal project shell.
  environment.loginShellInit = ''
    if [ "$PWD" = "$HOME" ]; then
      cd /workspace
    fi
  '';

  networking.hostName = "nixcage-vm";

  system.stateVersion = "24.11";
}
