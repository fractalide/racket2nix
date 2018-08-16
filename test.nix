{ pkgs ? import ./pkgs {}
, integration-test ? pkgs.callPackage ./integration-test {}
}:

let it-attrs = integration-test.attrs; in
let
  inherit (pkgs) buildRacketPackage racket2nix runCommand;
  attrs = rec {
  racket-doc = buildRacketPackage "racket-doc";
  typed-map-lib = buildRacketPackage "typed-map-lib";
  br-parser-tools-lib = buildRacketPackage "br-parser-tools-lib";

  light-tests = runCommand "light-tests" {
    buildInputs = [ typed-map-lib typed-map-lib.flat br-parser-tools-lib br-parser-tools-lib.flat ] ++
      builtins.attrValues integration-test;
  } ''touch $out'';
  heavy-tests = runCommand "heavy-tests" {
    buildInputs = [ racket-doc racket-doc.flat ];
  } ''touch $out'';
  integration-test = it-attrs;
};
in
attrs.light-tests // attrs
