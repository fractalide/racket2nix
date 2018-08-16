{ pkgs ? import ./pkgs {}
, integration-test ? pkgs.callPackage ./integration-test {}
}:

let it-attrs = integration-test.attrs; in
let
  inherit (pkgs) buildRacketPackage racket2nix stdenvNoCC;
  attrs = rec {
  racket-doc = buildRacketPackage "racket-doc";
  typed-map-lib = buildRacketPackage "typed-map-lib";
  br-parser-tools-lib = buildRacketPackage "br-parser-tools-lib";

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
