{ pkgs ? import ./pkgs {}
, catalog ? ./catalog.rktd
, package ? null
, flat ? false
}:

let
  inherit (pkgs) buildEnv lib nix racket2nix runCommand;
  default-catalog = catalog;

  attrs = rec {
    buildRacketNix = { catalog, flat, package}:
    runCommand "racket-package.nix" {
      inherit package;
      buildInputs = [ racket2nix nix ];
      flatArg = lib.optionalString flat "--flat";
    } ''
      racket2nix $flatArg --catalog ${catalog} $package > $out
    '';
    buildRacket = lib.makeOverridable ({ catalog ? default-catalog, flat ? false, package, attrOverrides ? (oldAttrs: {}) }:
      let
        nix = buildRacketNix { inherit catalog flat package; };
        self = (pkgs.callPackage nix {}).overrideAttrs attrOverrides;
      in self // {
        # We put the deps both in paths and buildInputs, so you can use this either as just
        #     nix-shell -A buildEnv
        # and get the environment-variable-only environment, or you can use it as
        #     nix-shell -p $(nix-build -A buildEnv)
        # and get the symlink tree environment.

        buildEnv = buildEnv rec {
          name = "${self.pname}-env";
          buildInputs = [ self ] ++ (self.propagatedBuildInputs or []);
          paths = buildInputs;
        };
        inherit nix;
      } //
        lib.optionalAttrs (! flat) { flat = buildRacket { inherit catalog package; flat = true; }; }
    );
    buildRacketPackage = package: buildRacket { inherit package; };
  };
in
attrs
