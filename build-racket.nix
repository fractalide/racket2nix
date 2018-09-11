{ pkgs ? import ./pkgs {}
, catalog ? ./catalog.rktd
, racket-package-overlays ? [ (import ./build-racket-default-overlay.nix) ]
, package ? null
, flat ? false
}:

let
  inherit (pkgs) buildEnv lib nix racket2nix runCommand;
  default-catalog = catalog;
  default-overlays = racket-package-overlays;

  attrs = rec {
    buildRacketNix = { catalog, flat, package, pname ? "racket-package" }:
    runCommand "${pname}.nix" {
      inherit package;
      buildInputs = [ racket2nix nix ];
      flatArg = lib.optionalString flat "--flat";
    } ''
      racket2nix $flatArg --catalog ${catalog} $package > $out
    '';
    buildRacket = lib.makeOverridable ({ catalog ? default-catalog, flat ? false, package, pname ? false,
                                         attrOverrides ? (oldAttrs: {}), overlays ? default-overlays }:
      let
        nix = buildRacketNix { inherit catalog flat package; } // lib.optionalAttrs (builtins.isString pname) { inherit pname; };
        self = let
          pname = ((pkgs.callPackage nix {}).overrideAttrs attrOverrides).pname;
          rpkgs = (pkgs.callPackage nix {}).racket-packages;
          racket-packages = let apply-overlays = rpkgs: overlays: if overlays == [] then rpkgs else
            apply-overlays (rpkgs.extend (builtins.head overlays)) (builtins.tail overlays);
          in
            apply-overlays rpkgs overlays;
        in
          (racket-packages."${pname}".overrideAttrs (oldAttrs: {
            passthru = oldAttrs.passthru or {} // { inherit racket-packages; };
          })).overrideAttrs attrOverrides;
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
    buildRacketCatalog = packages: let
      buildOneCatalog = package: runCommand "subcatalog.rktd" {
        buildInputs = [ racket2nix nix ];
        inherit catalog package packages;
      } ''
        racket2nix --export-catalog --no-process-catalog --catalog $catalog $package $packages --export-catalog > $out
      '';
    in runCommand "catalog.rktd" {
      buildInputs = [ racket2nix nix ];
      catalogs = map buildOneCatalog packages;
    } ''
      racket2nix --export-catalog --no-process-catalog $(printf -- '--catalog %s ' $catalogs) > $out
    '';
  };
in
attrs
