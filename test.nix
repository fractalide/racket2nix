{ pkgs ? import ./pkgs {}
, callPackage ? pkgs.callPackage
, integration-tests ? pkgs.callPackage ./integration-tests {}
}:

callPackage ({buildDrvs, buildRacket, buildRacketPackage, racket2nix}:
let it-attrs = integration-tests.attrs; in
let
  attrs = rec {
  racket-doc = buildRacketPackage "racket-doc";
  racket-index = buildRacketPackage "racket-index";
  typed-map-lib = buildRacket { package = "typed-map-lib"; buildNix = true; };

  all-checked-packages = let
    buildInputs = let
      wordsToList = words: builtins.filter (s: (builtins.isString s) && s != "") (builtins.split "[ \n]+" words);
    in map buildRacketPackage (wordsToList (builtins.readFile ./build-racket-install-check-overrides.txt));
  in buildDrvs "all-checked-packages" buildInputs;
  light-tests = buildDrvs "light-tests"
    ([ racket-index typed-map-lib typed-map-lib.flat ] ++
      builtins.attrValues integration-tests);
  heavy-tests = buildDrvs "heavy-tests" [ racket-doc racket-doc.flat ];
  integration-tests = it-attrs;
};
in
attrs.light-tests // attrs) {}
