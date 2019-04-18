self: super:
let
  inherit (super.pkgs) lib;
in

lib.optionalAttrs (super ? "deinprogramm-signature" && super ? "icons") {
  deinprogramm-signature = super.deinprogramm-signature.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "deinprogramm-signature+htdp-lib" && super ? "icons") {
  "deinprogramm-signature+htdp-lib" = super."deinprogramm-signature+htdp-lib".overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "gui-lib" && super ? "icons") {
  gui-lib = super.gui-lib.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "htdp-lib" && super ? "icons") {
  htdp-lib = super.htdp-lib.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "compatibility+compatibility-doc+data-doc+db-doc+distributed-p...") {
  "compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." = super."compatibility+compatibility-doc+data-doc+db-doc+distributed-p...".overrideAttrs (oldAttrs: {
  buildInputs = oldAttrs.buildInputs or [] ++ builtins.attrValues {
    inherit (self.pkgs) glib cairo fontconfig gmp gtk3 gsettings-desktop-schemas libedit libjpeg_turbo libpng mpfr openssl pango poppler readline sqlite;
  }; });
} //
lib.optionalAttrs (super ? "compiler-lib") (let
  mergeAttrs = builtins.foldl' (acc: attrs: acc // attrs) {};
  wordsToList = words: builtins.filter (s: (builtins.isString s) && s != "") (builtins.split "[ \n]+" words);
in mergeAttrs (map (package: lib.optionalAttrs (super ? "${package}") {
  "${package}" = super."${package}".overrideRacketDerivation (oldAttrs: { doInstallCheck = true; });
}) (wordsToList (builtins.readFile ./build-racket-install-check-overrides.txt))))
