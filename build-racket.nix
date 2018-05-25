{ pkgs ? import ./nixpkgs.nix { }
, lib ? pkgs.lib
, stdenvNoCC ? pkgs.stdenvNoCC
, nix ? pkgs.nix
, catalog ? ./catalog.rktd
, racket ? pkgs.callPackage ./racket-minimal.nix { }
, racket2nix ? pkgs.callPackage ./stage0.nix { inherit racket; }
, package ? null
}:

let
  attrs = rec {
    buildRacketNix = { flat, package}:
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
    buildRacket = lib.makeOverridable ({ flat ? false, package }:
      let nix = buildRacketNix { inherit flat package; };
      in (pkgs.callPackage nix { inherit racket; }) // { inherit nix; }
    );
  };
in
if package != null then attrs.buildRacket { inherit package; } else attrs
