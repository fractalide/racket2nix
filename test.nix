{ pkgs ? import ./nixpkgs { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, racket2nix ? pkgs.callPackage ./. { inherit racket; }
, buildRacket ? racket2nix.buildRacket
, integration-test ? pkgs.callPackage ./integration-test {}
}:

let
  buildRacketAndFlat = package: (buildRacket { inherit package; }) // {
    flat = buildRacket { inherit package; flat = true; };
  };
  attrs = rec {
  racket-doc = buildRacketAndFlat "racket-doc";
  typed-map-lib = buildRacketAndFlat "typed-map-lib";
  br-parser-tools-lib = buildRacketAndFlat "br-parser-tools-lib";

  light-tests = stdenvNoCC.mkDerivation {
    name = "light-tests";
    buildInputs = [ typed-map-lib typed-map-lib.flat br-parser-tools-lib br-parser-tools-lib.flat ] ++
      builtins.attrValues integration-test;
    phases = "installPhase";
    installPhase = ''touch $out'';
  };
  heavy-tests = stdenvNoCC.mkDerivation {
    name = "heavy-tests";
    buildInputs = [ racket-doc racket-doc.flat ];
    phases = "installPhase";
    installPhase = ''touch $out'';
  };
};
in
attrs.light-tests // attrs
