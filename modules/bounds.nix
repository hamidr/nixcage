## What a cage may use (ADR-022), imported by both platform modules: the
## host's default, and on a host with cages the bounds it declared for one.
## A quantity nixcage was told nothing about renders as "-", which the
## container script reads as nothing said rather than as a value.
{ config, lib, ... }:
let
  cfg = config.nixcage;
  ## The grammar the flag's own check accepts (modules/enter-args.sh), named
  ## here so a size that evaluates on the host cannot be refused at the enter.
  memoryType = lib.types.nullOr (lib.types.strMatching "[0-9]+[KMGT]?");
  word = value: if value == null then "-" else toString value;
  boundsOptions = {
    memory = lib.mkOption {
      type = memoryType;
      default = null;
      example = "4G";
      description = ''
        The memory a cage gets: the guest's RAM on a microVM, MemoryMax= on
        an nspawn cage's scope. Null leaves the substrate's own default,
        which is unbounded on nspawn and systemd-vmspawn's 2 GiB on a
        microVM. A session's --memory outranks this.
      '';
    };
    cpus = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 4;
      description = ''
        The cpus a cage gets: that many vCPUs on a microVM, CPUQuota= of
        that many whole cpus on an nspawn cage's scope. The two are not the
        same guarantee, and the declaration states the size of the machine
        rather than how it is enforced. A session's --cpus outranks this.
      '';
    };
  };
  cageBounds = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (path: cage: "${path} ${word cage.bounds.memory} ${word cage.bounds.cpus}") (
      lib.filterAttrs (_: cage: cage.bounds.memory != null || cage.bounds.cpus != null) (cfg.cages or { })
    )
  );
in
{
  options.nixcage = {
    bounds = lib.mkOption {
      type = lib.types.submodule { options = boundsOptions; };
      default = { };
      description = "What a cage on this machine may use when it says nothing else (ADR-022).";
    };

    ## The options a cage declares one of its own bounds with, so that the
    ## host module's cages submodule and this file agree on one shape.
    boundsOptions = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = boundsOptions;
    };

    ## The lines the container script reads them from. Rendered here so the
    ## two platform modules, which keep different amounts of this, spell it
    ## once.
    boundsConfigText = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = ''
        BOUNDS_DEFAULT="${word cfg.bounds.memory} ${word cfg.bounds.cpus}"
      ''
      + lib.optionalString (cageBounds != "") ''
        CAGE_BOUNDS="${cageBounds}"
      '';
    };
  };
}
