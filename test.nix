{ pkgs ? import ./pkgs {}
, integration-tests ? pkgs.callPackage ./integration-tests {}
}:

let it-attrs = integration-tests.attrs; in
let
  inherit (pkgs) buildRacket buildRacketPackage racket2nix runCommand;
  attrs = rec {
  racket-doc = buildRacketPackage "racket-doc";
  typed-map-lib = buildRacket { package = "typed-map-lib"; buildNix = true; };
  br-parser-tools-lib = buildRacketPackage "br-parser-tools-lib";

  all-checked-packages = runCommand "all-checked-packages" {
    buildInputs = let
      wordsToList = words: builtins.filter (s: (builtins.isString s) && s != "") (builtins.split "[ \n]+" words);
    in map buildRacketPackage (wordsToList (builtins.readFile ./build-racket-install-check-overrides.txt));
  } ''touch $out'';
  light-tests = runCommand "light-tests" {
    buildInputs = [ typed-map-lib typed-map-lib.flat br-parser-tools-lib br-parser-tools-lib.flat ] ++
      builtins.attrValues integration-tests;
  } ''touch $out'';
  heavy-tests = runCommand "heavy-tests" {
    buildInputs = [ racket-doc racket-doc.flat ];
  } ''touch $out'';
  integration-tests = it-attrs;
};
in
attrs.light-tests // attrs
