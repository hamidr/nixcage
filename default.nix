{
  pkgs ? import <nixpkgs> { },
}:

let
  runtimeDeps =
    with pkgs;
    [
      jq
      coreutils
      gnused
      bash
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
      bubblewrap
    ];
in
pkgs.stdenv.mkDerivation {
  pname = "nixcage";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp nixcage $out/bin/nixcage
    chmod +x $out/bin/nixcage

    wrapProgram $out/bin/nixcage \
      --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
  '';

  meta = with pkgs.lib; {
    description = "Sandboxed Nix environments with direnv integration";
    license = licenses.gpl3Only;
    platforms = platforms.unix;
  };
}
