## The CLI, built from whichever pkgs the caller has: the flake's own for
## `nix run`, a machine's for the overlay. One definition, because 5.1.0 had
## two and they drifted: the overlay's could not find its declaration reader.
{ pkgs }:
let
  inherit (pkgs) lib;
  runtimeDeps = with pkgs; [
    jq
    coreutils
    gnused
    bash
    openssh
    ## Where nothing was declared, a session's identity is whatever this
    ## user's own git answers with, so the CLI has to have one.
    git
  ];
  ## The container layer this nixcage carries. A host that imported
  ## nixosModules.host installs its own and the CLI uses that; where nothing
  ## was declared there is no other source, so the layer is part of what
  ## `nix run github:hamidr/nixcage` fetches (ADR-023). Linux only: nothing
  ## on darwin can run a cage, and container.nix asks for packages darwin
  ## does not have.
  container = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    import ./modules/container.nix { inherit pkgs; }
  );
  ## Named across sudo rather than inherited, since sudo clears the
  ## environment (ADR-023 decision 8).
  carriedLayer = lib.optionals (container ? script) [
    "--set NIXCAGE_CONTAINER ${container.script}/bin/nixcage-container"
    "--set NIXCAGE_PROFILE ${container.profile}"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "nixcage";
  version = "5.1.2";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp nixcage $out/bin/nixcage
    chmod +x $out/bin/nixcage

    wrapProgram $out/bin/nixcage \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set NIXCAGE_DECLARATION_SH ${./modules/declaration.sh} \
      ${lib.concatStringsSep " " carriedLayer}
  '';

  passthru = { inherit container; };

  meta = {
    description = "One shared NixOS microVM with per-project containers for AI coding agents";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.unix;
  };
}
