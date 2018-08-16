{ pkgs ? import ./pkgs {}
, catalog ? ./catalog.rktd
, package ? null
, flat ? false
}:

let
  inherit (pkgs) lib nix racket racket2nix runCommand;
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
    buildRacket = lib.makeOverridable ({ catalog ? default-catalog, flat ? false, package }:
      let nix = buildRacketNix { inherit catalog flat package; };
      in (pkgs.callPackage nix { inherit racket; }) // { inherit nix; } //
        lib.optionalAttrs (! flat) { flat = buildRacket { inherit catalog package; flat = true; }; }
    );
    buildRacketPackage = package: buildRacket { inherit package; };
  };
in
attrs
