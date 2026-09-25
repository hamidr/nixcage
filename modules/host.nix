## nixcage host module for Linux: project containers run directly on this
## machine, so there is no VM. Renders /etc/nixcage/config for the CLI and
## installs the same container layer the VM uses. Secrets come from the
## host's own sops-nix setup under /run/secrets.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcage;
  container = import ./container.nix {
    inherit pkgs;
    extraPackages = cfg.containerPackages;
    ## qemu and virtiofsd for vmspawn to find, ssh for exec to reach the
    ## guest with; the host's ssh_config carries systemd-ssh-proxy.
    microvmPackages = lib.optionals (cfg.microvm.enable || cfg.machines != { }) [
      pkgs.qemu_kvm
      pkgs.virtiofsd
      pkgs.openssh
    ];
  };
  ## Refused at evaluation of anything rendered from it: a default nothing
  ## can boot is not a default.
  substrateDefault =
    if cfg.substrate.default == "microvm" && !cfg.microvm.enable then
      throw "nixcage.substrate.default is microvm but nixcage.microvm.enable is false"
    else
      cfg.substrate.default;
  ## A cage is named by its project's path in a table whose lines are read
  ## word by word, so a path with whitespace in it would match nothing and
  ## every declaration for that cage would be silently ignored. Refused here,
  ## where an administrator is watching, rather than at an enter that quietly
  ## does none of what was declared.
  cages = lib.mapAttrs (
    path: cage:
    if lib.match ".*[[:space:]].*" path != null then
      throw "nixcage.cages.\"${path}\" cannot be declared: a cage's path is read as one word, so it may hold no whitespace"
    else
      cage
  ) cfg.cages;

  ## The roots are one colon-separated line for the same reason.
  workspaceRoots = map (
    root:
    if lib.hasInfix ":" root then
      throw "nixcage.workspaceRoots has a root with a colon in it: ${root}"
    else
      root
  ) cfg.workspaceRoots;

  ## One line per declared bind, its cage's path and the spec a session turns
  ## into an argument. A path with a .. segment would resolve somewhere the
  ## session's own check reads as allowed, so it is refused here as a
  ## spelling, where an administrator is watching.
  cageBinds = lib.concatStringsSep "\n" (
    lib.flatten (
      lib.mapAttrsToList (
        path: cage:
        map (
          bind:
          if lib.hasInfix "/../" bind || lib.hasSuffix "/.." bind then
            throw "nixcage.cages.${path}.binds has a .. segment: ${bind}"
          else
            "${path} ${bind}"
        ) cage.binds
      ) cages
    )
  );

  ## One line per declared cage, its path and its word; a cage declared on
  ## a substrate this host cannot boot is refused the same way.
  cageSubstrates = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      path: cage:
      if cage.substrate == "microvm" && !cfg.microvm.enable then
        throw "nixcage.cages.${path}.substrate is microvm but nixcage.microvm.enable is false"
      else
        "${path} ${cage.substrate}"
    ) (lib.filterAttrs (_: cage: cage.substrate != null) cages)
  );
  ## A machine's slice, as the half-open interval the checks compare.
  slices =
    lib.mapAttrsToList (name: m: {
      what = "nixcage.machines.${name}.uidSlice";
      lo = m.uidSlice.base;
      hi = m.uidSlice.base + m.uidSlice.size;
    }) cfg.machines
    ++ lib.optional (cfg.principalUidRange != null) {
      what = "nixcage.principalUidRange";
      lo = cfg.principalUidRange.base;
      hi = cfg.principalUidRange.base + cfg.principalUidRange.size;
    };
  overlapping = lib.concatLists (
    lib.imap0 (
      i: a:
      map (b: "${a.what} and ${b.what}") (
        lib.filter (b: a.lo < b.hi && b.lo < a.hi) (lib.drop (i + 1) slices)
      )
    ) slices
  );

  ## One guest per machine, from this host's pkgs, as a microVM session's
  ## is (ADR-026 decision 2): the session guest's boot, with no session in
  ## it, and this module in it, so the guest is a nixcage host.
  machineGuest =
    name: m:
    pkgs.nixos (
      [
        ./guest.nix
        ./machine-guest.nix
        ./host.nix
        {
          networking.hostName = lib.mkForce name;
          ## Each share at its host path, by the tag its position gives it;
          ## nothing on one is setuid or a device, read-only as declared.
          fileSystems = lib.listToAttrs (
            lib.imap0 (
              i: share:
              lib.nameValuePair share.path {
                device = "nixcage-share${toString i}";
                fsType = "virtiofs";
                options = [
                  "nosuid"
                  "nodev"
                ]
                ++ lib.optional (!share.writable) "ro";
              }
            ) m.shares
          );
        }
      ]
      ++ m.modules
    );
in
{
  ## The bridges a cage may be placed on (ADR-018), shared with the VM module.
  imports = [
    ./bridges.nix
    ./bounds.nix
  ];

  options.nixcage = {
    workspaceRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "/home/me/Src" ];
      description = ''
        Absolute directories whose flake subdirectories can be entered.
        Containers bind only their own project subdirectory.
      '';
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        ANTHROPIC_API_KEY = "anthropic";
      };
      description = ''
        Environment variable to sops secret name mapping. Each container
        session gets the variable set from this host's /run/secrets/<name>.
      '';
    };

    storage = lib.mkOption {
      type = lib.types.submodule {
        options = {
          dataset = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "tank/nixcage";
            description = ''
              The ZFS dataset mounted at /var/lib/nixcage, if this host keeps
              nixcage's state on one. Set it and every directory nixcage hands
              out becomes a child dataset, which is what makes a quota on one
              possible and what keeps an unclean shutdown from truncating what
              was written there.
              Left null, nixcage uses ordinary directories and behaves exactly
              as before; nothing here requires ZFS of a Linux host (ADR-017).
            '';
          };
        };
      };
      default = { };
      description = "Where nixcage keeps its state on this host.";
    };

    microvm = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Build the guest a microvm session boots (ADR-019) and put
              qemu and virtiofsd where systemd-vmspawn finds them. Off, a
              session asking for the microvm substrate is refused before
              anything boots, and nothing is built.
            '';
          };
          guestModules = lib.mkOption {
            type = lib.types.listOf lib.types.deferredModule;
            default = [ ];
            description = ''
              NixOS modules added to the guest, for what a host wants in
              every microVM that a session's own line does not carry.
              nixcage has no opinion about what belongs here.
            '';
          };
          guest = lib.mkOption {
            type = lib.types.raw;
            readOnly = true;
            description = "The guest as evaluated: its config, and its toplevel under config.system.build.";
          };
        };
      };
      default = { };
      description = "The microVM substrate a cage may run on (ADR-019).";
    };

    machines = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              memory = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "4G";
                description = "The machine's memory, reserved while it runs. Null is vmspawn's default.";
              };
              cpus = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "The machine's cores. Null is vmspawn's default.";
              };
              diskSize = lib.mkOption {
                type = lib.types.str;
                example = "20G";
                description = ''
                  The size of the machine's disk, a raw image under the
                  state directory that only qemu opens. It bounds every cage
                  in the machine together; a cage inside has no quota of
                  its own. Fixed when the image is first made.
                '';
              };
              uidSlice = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    base = lib.mkOption {
                      type = lib.types.ints.positive;
                      example = 900000;
                      description = "The first host uid the machine's ids are shifted onto.";
                    };
                    size = lib.mkOption {
                      type = lib.types.ints.positive;
                      default = 65536;
                      description = "How many ids the slice covers.";
                    };
                  };
                };
                description = ''
                  The host uids what the guest writes through a share is
                  owned by: guest uid 0 is the base. Disjoint from every
                  other machine's and from principalUidRange, which
                  evaluation asserts.
                '';
              };
              placement = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
                      bridge = lib.mkOption {
                        type = lib.types.str;
                        example = "fb-0";
                        description = "The host bridge the machine's tap is a port of.";
                      };
                      addresses = lib.mkOption {
                        type = lib.types.nonEmptyListOf lib.types.str;
                        example = [
                          "10.77.0.2"
                          "10.77.0.10"
                        ];
                        description = ''
                          Every address the machine and its cages may speak
                          as on the bridge. The tap is pinned to these and to
                          nothing else, whatever the guest does.
                        '';
                      };
                    };
                  }
                );
                default = null;
                description = "The host bridge the machine is placed on (ADR-026 decision 9).";
              };
              shares = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      path = lib.mkOption {
                        type = lib.types.str;
                        example = "/srv/checkout";
                        description = "A host directory, shared at the same path in the machine.";
                      };
                      writable = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = ''
                          Whether the machine may write it. What it writes is
                          owned here by the machine's slice, never by an id
                          outside it, and the directory must be on a mount
                          with nosuid and nodev, which the machine's start
                          checks.
                        '';
                      };
                    };
                  }
                );
                default = [ ];
                description = "Host directories the machine sees (ADR-026 decision 5).";
              };
              modules = lib.mkOption {
                type = lib.types.listOf lib.types.deferredModule;
                default = [ ];
                description = ''
                  NixOS modules the machine's guest also imports: what a
                  dependant runs in the machine besides nixcage. nixcage has
                  no opinion about what belongs here.
                '';
              };
              guest = lib.mkOption {
                type = lib.types.raw;
                readOnly = true;
                default = machineGuest name config;
                description = "The machine's guest as evaluated.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Long-lived microVMs that are nixcage hosts themselves (ADR-026),
        started with `nixcage-container machine up <name>` and reached by the
        verbs over a cage with `--machine <name>`.
      '';
    };

    cages = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.substrate = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "nspawn"
                "microvm"
              ]
            );
            default = null;
            description = ''
              What this cage runs on (ADR-019), by the project's absolute
              path. Outranks the record of the cage's first enter and the
              flag; a flag against it is refused naming this declaration.
              Null leaves the choice to the record, the flag and the host's
              default, which is what a cage declared only for its bounds
              wants.
            '';
          };

          options.bounds = lib.mkOption {
            type = lib.types.submodule { options = config.nixcage.boundsOptions; };
            default = { };
            description = "What this cage may use (ADR-022), outranked by a session's own flags.";
          };

          options.binds = lib.mkOption {
            ## Shape only. What a destination may be is the session's answer,
            ## where one list of refusals already lives; a second copy here
            ## would be two lists to keep in step.
            type = lib.types.listOf (
              lib.types.strMatching "/[^:]*:/[^:]*(:ro)?"
            );
            default = [ ];
            example = [ "/srv/models:/models:ro" ];
            description = ''
              Paths this cage always has, written SRC:DST, or SRC:DST:ro for
              one the session may not write. Added to whatever the session
              asks for with its own --bind; two binds naming one destination
              are refused at the session, naming both.

              This is the host adding to a session its caller did not ask
              for, which is the host's standing on its own machine. A caller
              that wants a path for one session asks for it with a flag.
            '';
          };
        }
      );
      default = { };
      example = {
        "/home/me/Src/untrusted".substrate = "microvm";
      };
      description = "Cages the host has something to say about, by project path.";
    };

    substrate = lib.mkOption {
      type = lib.types.submodule {
        options.default = lib.mkOption {
          type = lib.types.enum [
            "nspawn"
            "microvm"
          ];
          default = "nspawn";
          description = ''
            What a cage runs on when neither its declaration, its record nor
            the enter flag says (ADR-019). The choice is made when the cage
            is defined and then fixed.
          '';
        };
      };
      default = { };
      description = "The substrate a cage runs on when nothing closer decides.";
    };

    principalUidRange = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            base = lib.mkOption {
              type = lib.types.ints.unsigned;
              example = 700000;
              description = "First uid a principal may be allocated.";
            };
            size = lib.mkOption {
              type = lib.types.ints.positive;
              default = 64;
              description = "How many uids the range covers.";
            };
          };
        }
      );
      default = null;
      description = ''
        The uid range `nixcage-container uid` allocates from (ADR-004). A
        principal is whatever a caller wants a durable uid for; nixcage only
        promises that one name always answers with one number and that a
        forgotten name's number is never reissued, so nothing new can inherit
        a dead principal's files. The range must not overlap accounts that
        already exist on this host.
      '';
    };

    machineGuest = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = "Set by a machine's guest (ADR-026): this host is a machine, and a quota is refused.";
    };

    storeBase = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        What every session without the daemon closes over besides its own
        roots: the profile and the session's own files. Read by the host a
        machine runs on, which computes the machine's closures.
      '';
    };

    containerPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ripgrep ]";
      description = ''
        Packages every session's userland carries, on top of the minimal one
        nixcage provides. For a dependant that needs something present in every
        cage whatever a project declares: `enter` takes binds and environment
        and never packages, so there is otherwise no way to put one there.

        nixcage has no opinion about what belongs in this list. What goes in it
        is the host's business, which is what keeps the decision on the side
        that knows why it is being made.
      '';
    };

    principalSubjects = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "agent" ];
      description = ''
        The subjects every cage has besides its root (ADR-010). A principal is
        allocated one uid per subject plus one for cage root, contiguously, so
        a supervising process and the program it supervises can be different
        principals inside one cage. Declaring none is the ADR-004 behaviour: a
        block of one, and a session that is cage root.

        A block is fixed when it is allocated. Declaring a subject does not
        widen a principal allocated before it, because the uid after that
        block already belongs to somebody else.
      '';
    };

    git = lib.mkOption {
      type = lib.types.submodule {
        options = {
          userName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Ada Lovelace";
            description = "Committer name every session uses. No identity is rendered unless both this and userEmail are set.";
          };
          userEmail = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ada@example.org";
            description = "Committer email every session uses.";
          };
          signing.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Sign commits and tags through the ssh-agent the CLI forwards
              into the session. No key material is copied in, and a session
              entered without a reachable agent simply fails to sign.
            '';
          };
        };
      };
      default = { };
      description = "Git identity and signing for container sessions.";
    };
  };

  config = lib.mkMerge [
    {
    environment.systemPackages = [ container.script ];

    ## One declaration a host renders and one reader answers from, versioned
    ## because a nixcage installed on its own can stand on a module older or
    ## newer than itself. Every key a session or the CLI reads is here; what
    ## is not here is the profile, which is a symlink to a store path rather
    ## than something a line of text says better.
    environment.etc."nixcage/declaration".text = ''
      DECLARATION_VERSION=1
      HOST_PLATFORM=linux
      WORKSPACE_ROOTS=${lib.concatStringsSep ":" workspaceRoots}
      SUBSTRATE_DEFAULT=${substrateDefault}
      CAGE_SUBSTRATES="${cageSubstrates}"
      CAGE_BINDS="${cageBinds}"
      ${cfg.boundsConfigText}${lib.optionalString cfg.microvm.enable ''
        MICROVM_GUEST=${cfg.microvm.guest.config.system.build.toplevel}
      ''}${lib.optionalString (cfg.principalUidRange != null) ''
        PRINCIPAL_UID_BASE=${toString cfg.principalUidRange.base}
        PRINCIPAL_UID_SIZE=${toString cfg.principalUidRange.size}
      ''}PRINCIPAL_SUBJECTS="${lib.concatStringsSep " " cfg.principalSubjects}"
      STORAGE_DATASET=${lib.optionalString (cfg.storage.dataset != null) cfg.storage.dataset}
      SECRET_ENV="${
        lib.concatStringsSep " " (lib.mapAttrsToList (var: secret: "${var}=${secret}") cfg.secretEnv)
      }"
      ${lib.optionalString (cfg.git.userName != null) ''
        GIT_USER_NAME="${cfg.git.userName}"
      ''}${lib.optionalString (cfg.git.userEmail != null) ''
        GIT_USER_EMAIL="${cfg.git.userEmail}"
      ''}GIT_SIGNING=${if cfg.git.signing.enable then "1" else ""}
      ${lib.optionalString cfg.machineGuest "MACHINE_GUEST=1"}
    '';

    nixcage.storeBase = container.storeBase;

    ## One guest per host, from this host's pkgs (ADR-019 decision 3).
    nixcage.microvm.guest = pkgs.nixos ([ ./guest.nix ] ++ cfg.microvm.guestModules);

    ## The one key a CLI older than this module reads, kept where it looks
    ## for one release. A machine rebuilds with this module while the nixcage
    ## someone installed separately is still the one before it, and without
    ## this that CLI tells a person who has just imported the module to go
    ## and import it.
    environment.etc."nixcage/config".text = ''
      WORKSPACE_ROOTS=${lib.concatStringsSep ":" workspaceRoots}
    '';

    environment.etc."nixcage/profile".source = container.profile;

    ## The container homes and skeletons live where the VM keeps them, so
    ## the container script needs no platform branch.
    systemd.tmpfiles.rules = [
      "d /var/lib/nixcage 0755 root root -"
    ];
    }
    {
    assertions = [
      {
        assertion = overlapping == [ ];
        message = "nixcage: uid slices overlap: ${lib.concatStringsSep "; " overlapping}";
      }
    ]
    ++ lib.mapAttrsToList (name: _: {
      assertion = builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]*" name != null && lib.stringLength name <= 64;
      message = "nixcage.machines.${name}: a machine is named as a cage is";
    }) cfg.machines;

    environment.etc = lib.mapAttrs' (
      name: m:
      lib.nameValuePair "nixcage/machines/${name}" {
        text = ''
          TOPLEVEL=${m.guest.config.system.build.toplevel}
          MEMORY=${lib.optionalString (m.memory != null) m.memory}
          CPUS=${lib.optionalString (m.cpus != null) (toString m.cpus)}
          DISK_SIZE=${m.diskSize}
          UID_BASE=${toString m.uidSlice.base}
          UID_SIZE=${toString m.uidSlice.size}
          STORE_BASE=${lib.concatStringsSep " " m.guest.config.nixcage.storeBase}
          BRIDGE=${lib.optionalString (m.placement != null) m.placement.bridge}
          ADDRESSES=${lib.optionalString (m.placement != null) (lib.concatStringsSep " " m.placement.addresses)}
          SHARES=${
            lib.concatMapStringsSep " " (
              share:
              if builtins.match "/[^:[:space:]]*" share.path == null then
                throw "nixcage.machines.${name}.shares: ${share.path} is not an absolute path without colons or whitespace"
              else
                "${share.path}:${if share.writable then "rw" else "ro"}"
            ) m.shares
          }
        '';
      }
    ) cfg.machines;

    ## Started by `machine up`, never at boot: a dependant decides when a
    ## machine runs. Its stop is the host's cleanup, whatever ended qemu.
    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "nixcage-machine-${name}" {
        description = "nixcage machine ${name}";
        after = [ "network.target" ];
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "all";
          ExecStart = "${container.script}/bin/nixcage-container machine run ${name}";
          ExecStopPost = "${container.script}/bin/nixcage-container machine reap ${name}";
          KillMode = "mixed";
          TimeoutStopSec = 30;
        };
      }
    ) cfg.machines;

    }
  ];
}
