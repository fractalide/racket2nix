{ pkgs ? import <nixpkgs> { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.racket-minimal
, racket-catalog ? pkgs.callPackage ./catalog.nix { inherit racket; }
}:

let attrs = rec {
  racket2nix-stage0-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix-stage0.nix";
    src = ./nix;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -N racket2nix ./racket2nix.rkt --catalog ${racket-catalog} ../nix > $out
    '';
  };
  racket2nix-stage0 = (pkgs.callPackage racket2nix-stage0-nix { inherit racket; }).overrideDerivation (drv: rec { src = ./nix; srcs = [ src ]; });
};
in
attrs.racket2nix-stage0 // attrs
