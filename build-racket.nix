{ pkgs ? import ./nixpkgs { }
, lib ? pkgs.lib
, stdenvNoCC ? pkgs.stdenvNoCC
, nix ? pkgs.nix
, catalog ? ./catalog.rktd
, racket ? pkgs.callPackage ./racket-minimal.nix { }
, racket2nix ? pkgs.callPackage ./stage0.nix { inherit racket; }
, package ? null
, flat ? false
}:

let
  attrs = rec {
    buildRacketNix = { catalog ? catalog, flat, package}:
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
    buildRacket = lib.makeOverridable ({ catalog ? catalog, flat ? false, package }:
      let nix = buildRacketNix { inherit catalog flat package; };
      in (pkgs.callPackage nix { inherit racket; }) // { inherit nix; }
    );
  };
in
if package != null then attrs.buildRacket { inherit catalog package flat; } else attrs
