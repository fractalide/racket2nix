{ pkgs ? import ./nixpkgs.nix { }
, stdenvNoCC ? pkgs.stdenvNoCC
, build-racket ? pkgs.callPackage ./build-racket.nix { inherit racket; }
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, nix-prefetch-git ? pkgs.nix-prefetch-git
, racket-catalog ? pkgs.callPackage ./catalog.nix { inherit racket; }
, racket2nix-stage0 ? pkgs.callPackage ./stage0.nix { inherit racket; }
, racket2nix-stage0-nix ? racket2nix-stage0.racket2nix-stage0-nix
}:

let attrs = rec {
  inherit (build-racket) buildRacket;
  racket2nix-stage1-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ racket2nix-stage0 ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket2nix --catalog ${racket-catalog} ../nix > $out
      diff ${racket2nix-stage0-nix} $out
    '';
  };
  racket2nix-stage1 = (pkgs.callPackage racket2nix-stage1-nix { inherit racket; }).racketDerivation.override {
    src = ./nix;
    postInstall = ''
      $out/bin/racket2nix --test
    '';
  };
  racket2nix = racket2nix-stage1;

  racket2nix-flat-stage0-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -N racket2nix ./racket2nix.rkt --flat --catalog ${racket-catalog} ../nix > $out
    '';
  };
  racket2nix-flat-stage0 = (pkgs.callPackage racket2nix-flat-stage0-nix { inherit racket; }).racketDerivation.override {
    src = ./nix;
    postInstall = ''
      $out/bin/racket2nix --test
    '';
  };
  racket2nix-flat-stage1-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ racket2nix-flat-stage0 ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket2nix --flat --catalog ${racket-catalog} ../nix > $out
      diff ${racket2nix-flat-stage0-nix} $out
    '';
  };
  racket2nix-flat-nix = racket2nix-flat-stage1-nix;
  racket2nix-env = stdenvNoCC.mkDerivation {
    phases = [];
    buildInputs = [ racket2nix nix-prefetch-git ];
    name = "racket2nix-env";
  };
};
in
attrs.racket2nix // attrs
