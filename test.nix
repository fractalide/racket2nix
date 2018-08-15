{ pkgs ? import ./pkgs {}
, integration-test ? pkgs.callPackage ./integration-test {}
}:

let it-attrs = integration-test.attrs; in
let
  inherit (pkgs) buildRacket racket racket2nix stdenvNoCC;
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
  integration-test = it-attrs;
};
in
attrs.light-tests // attrs
