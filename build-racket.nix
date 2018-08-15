{ pkgs ? import ./pkgs {}
, lib ? pkgs.lib
, stdenvNoCC ? pkgs.stdenvNoCC
, nix ? pkgs.nix
, racket ? pkgs.racket
, racket2nix ? pkgs.racket2nix
, catalog ? ./catalog.rktd
, package ? null
, flat ? false
}:

let
  default-catalog = catalog;
  attrs = rec {
    buildRacketNix = { catalog, flat, package}:
    stdenvNoCC.mkDerivation {
      name = "racket-package.nix";
      inherit package;
      buildInputs = [ racket2nix nix ];
      phases = "installPhase";
      flatArg = lib.optionalString flat "--flat";
      installPhase = ''
        racket2nix $flatArg --catalog ${catalog} $package > $out
      '';
    };
    buildRacket = lib.makeOverridable ({ catalog ? default-catalog, flat ? false, package }:
      let nix = buildRacketNix { inherit catalog flat package; };
      in (pkgs.callPackage nix { inherit racket; }) // { inherit nix; }
    );
  };
in
if package != null then attrs.buildRacket { inherit catalog package flat; } else attrs
