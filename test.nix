{ pkgs ? import ./pkgs {}
, buildDrvs ? pkgs.buildDrvs
, integration-tests ? pkgs.callPackage ./integration-tests {}
}:

let it-attrs = integration-tests.attrs; in
let
  inherit (pkgs) buildRacket buildRacketPackage racket2nix;
  attrs = rec {
  racket-doc = buildRacketPackage "racket-doc";
  typed-map-lib = buildRacket { package = "typed-map-lib"; buildNix = true; };
  br-parser-tools-lib = buildRacketPackage "br-parser-tools-lib";

  all-checked-packages = let
    buildInputs = let
      wordsToList = words: builtins.filter (s: (builtins.isString s) && s != "") (builtins.split "[ \n]+" words);
    in map buildRacketPackage (wordsToList (builtins.readFile ./build-racket-install-check-overrides.txt));
  in buildDrvs "all-checked-packages" buildInputs;
  light-tests = buildDrvs "light-tests"
    ([ typed-map-lib typed-map-lib.flat br-parser-tools-lib br-parser-tools-lib.flat ] ++
      builtins.attrValues integration-tests);
  heavy-tests = buildDrvs "heavy-tests" [ racket-doc racket-doc.flat ];
  integration-tests = it-attrs;
};
in
attrs.light-tests // attrs
