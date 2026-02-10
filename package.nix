{
  stdenv,
  lib,
  makeWrapper,
  jq,
  coreutils,
  gnused,
  bash,
  bubblewrap,
}:
let
  runtimeDeps =
    [
      jq
      coreutils
      gnused
      bash
    ]
    ++ lib.optionals stdenv.isLinux [
      bubblewrap
    ];
in
stdenv.mkDerivation {
  pname = "nixcage";
  version = "0.3.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp nixcage $out/bin/nixcage
    chmod +x $out/bin/nixcage

    wrapProgram $out/bin/nixcage \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';

  meta = with lib; {
    description = "Sandboxed Nix environments with direnv integration";
    license = licenses.gpl3Only;
    platforms = platforms.unix;
  };
}
