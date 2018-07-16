{ pkgs ? import ./nixpkgs.nix { inherit system; }
, stdenvNoCC ? pkgs.stdenvNoCC
, build-racket ? pkgs.callPackage ./build-racket.nix { inherit racket; }
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, nix ? pkgs.nix
, nix-prefetch-git ? pkgs.nix-prefetch-git
, racket-catalog ? ./catalog.rktd
, racket2nix-stage0 ? pkgs.callPackage ./stage0.nix { inherit racket; }
, racket2nix-stage0-nix ? racket2nix-stage0.racket2nix-stage0-nix
, system ? builtins.currentSystem
, package ? null
, flat ? false
}:

let attrs = rec {
  inherit (build-racket) buildRacket;
  racket2nix-stage1-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ nix racket2nix-stage0 ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket2nix --catalog ${racket-catalog} ../nix > $out
      diff ${racket2nix-stage0-nix} $out
    '';
  };
  racket2nix-stage1 = ((pkgs.callPackage racket2nix-stage1-nix { inherit racket; }).racketDerivation.override {
    src = ./nix;
    postInstall = ''
      $out/bin/racket2nix --test
    '';
  }).overrideAttrs (oldAttrs: { buildInputs = oldAttrs.buildInputs ++ [ nix ]; });
  racket2nix = racket2nix-stage1;

  racket2nix-flat-stage0-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ nix racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -N racket2nix ./racket2nix.rkt --flat --catalog ${racket-catalog} ../nix > $out
    '';
  };
  racket2nix-flat-stage0 = ((pkgs.callPackage racket2nix-flat-stage0-nix { inherit racket; }).racketDerivation.override {
    src = ./nix;
    postInstall = ''
      $out/bin/racket2nix --test
    '';
  }).overrideAttrs (oldAttrs: { buildInputs = oldAttrs.buildInputs ++ [ nix ]; });
  racket2nix-flat-stage1-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./nix;
    buildInputs = [ nix racket2nix-flat-stage0 ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket2nix --flat --catalog ${racket-catalog} ../nix > $out
      diff ${racket2nix-flat-stage0-nix} $out
    '';
  };
  racket2nix-flat-nix = racket2nix-flat-stage1-nix;
  racket2nix-env = stdenvNoCC.mkDerivation {
    phases = [];
    buildInputs = [ nix nix-prefetch-git racket2nix ];
    name = "racket2nix-env";
  };
};
in
if package == null then (attrs.racket2nix // attrs) else attrs.buildRacket { inherit package flat; }
