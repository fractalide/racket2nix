{ pkgs ? import ./pkgs {}
, cacert ? pkgs.cacert
, catalog ? ./catalog.rktd
, racket-package-overlays ? [ (import ./build-racket-racket2nix-overlay.nix) (import ./build-racket-install-check-overlay.nix) (import ./build-racket-default-overlay.nix) ]
, racket-packages ? pkgs.callPackage ./racket-packages.nix {}
}:

let
  inherit (pkgs) buildEnv lib nix racket2nix runCommand;
  default = { inherit catalog racket-package-overlays racket-packages; };
  apply-overlays = rpkgs: overlays: if overlays == [] then rpkgs else
    apply-overlays (rpkgs.extend (builtins.head overlays)) (builtins.tail overlays);

  attrs = rec {
    buildThinRacketNix = { package, pname }:
      let
        sha256 = runCommand "${pname}.sha256" { buildInputs = [ nix ]; inherit package; } ''
          printf '%s' $(nix-hash --base32 --type sha256 $package) > $out
        '';
        path = runCommand pname {
          inherit package; outputHashMode = "recursive"; outputHashAlgo = "sha256";
          outputHash = builtins.readFile sha256;
        } ''
          cp -a $package $out
        '';
      in runCommand "${pname}.nix" {
        buildInputs = [ cacert racket2nix nix ];
        inherit path;
      } ''
        racket2nix --thin $path > $out
      '';
    buildThinRacket = { package, racket-packages ? default.racket-packages
                      , overlays ? default.racket-package-overlays
                      , attrOverrides ? (oldAttrs: {})
                      , pname ? builtins.readFile (runCommand "pname" { inherit package; } ''
                          printf '%s' $(basename $(stripHash "$package")) > $out
                        '')
                      }: let
      base = { inherit pname racket-packages overlays; }; in let
      nix = buildThinRacketNix { inherit package pname; };
      overlays = base.overlays ++ [ (import nix) ];
      racket-packages = apply-overlays base.racket-packages overlays;
      buildEnv = buildEnv rec {
        name = "${pname}-env";
        buildInputs = [ self ] ++ (self.propagatedBuildInputs or []);
        paths = buildInputs;
      };
      self = (racket-packages."${pname}".overrideAttrs (oldAttrs: {
        passthru = oldAttrs.passthru or {} // { inherit nix overlays racket-packages buildEnv; };
      })).overrideAttrs attrOverrides;
    in self;
    buildThinRacketPackage = package: buildThinRacket { inherit package; };

    buildRacketNix = { catalog, flat, package, pname ? "racket-package" }:
    runCommand "${pname}.nix" {
      inherit package;
      buildInputs = [ cacert racket2nix nix ];
      flatArg = lib.optionalString flat "--flat";
    } ''
      racket2nix $flatArg --catalog ${catalog} $package > $out
    '';
    buildRacket = lib.makeOverridable ({ catalog ? default.catalog, flat ? false, package, pname ? false
                                       , attrOverrides ? (oldAttrs: {}), overlays ? default.racket-package-overlays
                                       , buildNix ? !(builtins.isString package) || flat
                                       }:
      let
        nix = if !buildNix then null else
          buildRacketNix { inherit catalog flat package; } // lib.optionalAttrs (builtins.isString pname) { inherit pname; };
        self = let
          pname = if buildNix then ((pkgs.callPackage nix {}).overrideAttrs attrOverrides).pname else package;
          rpkgs = if buildNix then (pkgs.callPackage nix {}).racket-packages else default.racket-packages;
          racket-packages = apply-overlays rpkgs overlays;
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
        buildInputs = [ cacert racket2nix nix ];
        inherit catalog package packages;
      } ''
        racket2nix --export-catalog --no-process-catalog --catalog $catalog $package $packages --export-catalog > $out
      '';
    in runCommand "catalog.rktd" {
      buildInputs = [ cacert racket2nix nix ];
      catalogs = map buildOneCatalog packages;
    } ''
      racket2nix --export-catalog --no-process-catalog $(printf -- '--catalog %s ' $catalogs) > $out
    '';
  };
in
attrs
