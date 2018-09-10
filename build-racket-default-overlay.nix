let inherit (import ./pkgs {}) lib; in

self: super:
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
}
