## nixcage VM configuration flake. You own this file; edit freely and run
## 'nixcage rebuild' to apply. The nixcage CLI finds it at ~/.config/nixcage
## (override with --flake or NIXCAGE_FLAKE).
{
  description = "nixcage shared VM configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixcage = {
      url = "github:hamidr/nixcage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      microvm,
      nixcage,
      sops-nix,
      ...
    }:
    let
      ## The guest is always Linux. Match your CPU: aarch64-linux on Apple
      ## Silicon and other arm64 machines, x86_64-linux on Intel/AMD.
      guestSystem = "aarch64-linux";

      ## Uncomment on macOS so the qemu runner is a host-native binary.
      # hostSystem = "aarch64-darwin";
    in
    {
      nixosConfigurations.nixcage = nixpkgs.lib.nixosSystem {
        system = guestSystem;
        modules = [
          microvm.nixosModules.microvm
          nixcage.nixosModules.nixcage
          sops-nix.nixosModules.sops
          {
            nixcage = {
              ## Only flake directories under these roots can be entered.
              workspaceRoots = [ "/home/me/Src" ];

              ## Paste the key printed by 'nixcage status' (generated at
              ## ~/.local/state/nixcage/id_ed25519.pub on first run).
              authorizedKeys = [ ];

              ## Environment variable -> sops secret name, injected into
              ## every container session.
              # secretEnv.ANTHROPIC_API_KEY = "anthropic";

              # vm = { cpus = 8; mem = 8192; diskSize = 40960; };

              ## The VM keeps its state on a ZFS pool of its own (ADR-017).
              ## Once the first boot has copied the old ext4 volume's contents
              ## into it -- the storage service says when it has -- set this
              ## false and delete nixcage-data.img from the state directory.
              # vm.legacyDataVolume = false;

              ## The uid range nixcage allocates from when something asks it
              ## for a principal's number -- cageworks does, for each of its
              ## roles. Uncomment to allow it; the range must not overlap any
              ## account that exists in the VM.
              #
              # principalUidRange = { base = 700000; size = 64; };
            };

            ## Uncomment on macOS (see hostSystem above).
            # microvm.vmHostPackages = nixpkgs.legacyPackages.${hostSystem};

            ## Secrets: encrypt secrets.yaml with sops + the VM's age key
            ## ('nixcage status' prints the public key for .sops.yaml).
            ## The key never leaves the VM's data volume.
            sops.age.keyFile = "/var/lib/nixcage/age.key";
            # sops.defaultSopsFile = ./secrets.yaml;
            # sops.secrets.anthropic = { };
          }
        ];
      };
    };
}
