## A bridge a cage may be placed on (ADR-018), declared once and imported
## by the host module and the VM module alike.
##
## A bridge whose only ports are cages is empty whenever no session runs,
## and NixOS does not make an empty bridge usable on its own: networkd
## withholds an address from a link without carrier, so every service that
## listens on the bridge's address fails to bind until the first cage
## arrives; and a service that binds before the address is up needs the
## kernel told that a nonlocal bind is fine. Both were found by services
## failing on a booted machine. They are facts about any bridge whose ports
## come and go, so they live beside the module that adds the ports.
##
## Which ports a cage may reach on the bridge's own address is the host's
## firewall and the caller's to open; nothing is opened here. What crosses
## between ports is ADR-015's.
{
  config,
  lib,
  ...
}:
let
  cfg = config.nixcage;
  ## The kernel's fifteen characters and an interface's alphabet, the same
  ## check enter --network applies to the name it is given (enter-args.sh).
  nameOk = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]{0,14}" name != null;
  ## Refused at evaluation of anything rendered from it, not only at the
  ## system's assertions: a name that could not be an interface is not a
  ## bridge whatever else is declared. Checked over the set as a whole, since
  ## what is rendered reads the names and need never force a value.
  badNames = lib.filter (name: !nameOk name) (lib.attrNames cfg.bridges);
  bridges =
    if badNames == [ ] then
      cfg.bridges
    else
      throw "nixcage.bridges.${lib.head badNames}: not an interface name (at most fifteen characters of [a-zA-Z0-9._-], starting with a letter or digit)";
in
{
  options.nixcage.bridges = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.str;
            example = "10.77.0.1";
            description = "The host's own address on the bridge, the one a cage placed on it reaches.";
          };
          prefix = lib.mkOption {
            type = lib.types.ints.between 0 32;
            example = 24;
            description = "The prefix length of that address.";
          };
          uplink = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "eth0";
            description = ''
              An interface enslaved to the bridge, for a machine's guest
              (ADR-026): its NIC, so a cage placed here reaches the host's
              bridge with its own address. Null on a host, whose bridge
              has only cages for ports.
            '';
          };
        };
      }
    );
    default = { };
    example = {
      fabriek0 = {
        address = "10.77.0.1";
        prefix = 24;
      };
    };
    description = ''
      Bridges a cage may be placed on with `enter --network <name>:<addr>/<prefix>`.
      Each is declared with no static ports, given the address, configured
      without carrier so the address is there before the first cage is, and
      the kernel is told a service may bind it before it is up. Nothing is
      opened on it: what a cage may reach on the address is the host's
      firewall to say.
    '';
  };

  config = {
    networking.bridges = lib.mapAttrs (_: bridge: {
      interfaces = lib.optional (bridge.uplink != null) bridge.uplink;
    }) bridges;
    networking.interfaces = lib.mapAttrs (_: bridge: {
      ipv4.addresses = [
        {
          inherit (bridge) address;
          prefixLength = bridge.prefix;
        }
      ];
    }) bridges;
    systemd.network.networks = lib.mapAttrs' (
      name: _: lib.nameValuePair "40-${name}" { networkConfig.ConfigureWithoutCarrier = true; }
    ) bridges;
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkIf (bridges != { }) 1;
  };
}
