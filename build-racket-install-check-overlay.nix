self: super:
let
  inherit (super.pkgs) lib;
in

lib.optionalAttrs (super ? "compiler-lib") (let
  mergeAttrs = builtins.foldl' (acc: attrs: acc // attrs) {};
  wordsToList = words: builtins.filter (s: (builtins.isString s) && s != "") (builtins.split "[ \n]+" words);
in mergeAttrs (map (package: lib.optionalAttrs (super ? "${package}") {
  "${package}" = super."${package}".overrideRacketDerivation (oldAttrs: { doInstallCheck = true; });
}) (wordsToList (builtins.readFile ./build-racket-install-check-overrides.txt))))
