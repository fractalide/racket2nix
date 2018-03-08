{ pkgs ? import <nixpkgs> { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.racket-minimal
, cacert ? pkgs.cacert
}:

let attrs = rec {
  racket-catalog = stdenvNoCC.mkDerivation {
    name = "pkgs-all";
    src = ./.;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      $racket/bin/racket -N dump-catalogs ./nix/dump-catalogs.rkt https://download.racket-lang.org/releases/6.12/catalog/ > $out
    '';
    inherit racket;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1p8f4yrnv9ny135a41brxh7k740aiz6m41l67bz8ap1rlq2x7pgm";
  };
  default-nix-stage0 = stdenvNoCC.mkDerivation {
    name = "racket2nix-stage0.nix";
    src = ./.;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -N racket2nix ./nix/racket2nix.rkt --catalog ${racket-catalog} ./nix > $out
    '';
  };
  racket2nix-stage0 = (pkgs.callPackage default-nix-stage0 { inherit racket; }).overrideDerivation (drv: rec { src = ./nix; srcs = [ src ]; });
  default-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix.nix";
    src = ./.;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -G ${racket2nix-stage0}/etc/racket -N racket2nix -l- nix/racket2nix --catalog ${racket-catalog} ./nix > $out
      diff ${default-nix-stage0} $out
    '';
  };
  racket2nix = (pkgs.callPackage default-nix { inherit racket; }).overrideDerivation (drv: rec { src = ./nix; srcs = [ src ]; });
};
in
attrs.default-nix // attrs
