{ pkgs ? import <nixpkgs> { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.racket-minimal
, racket2nix ? pkgs.callPackage ./. { inherit racket; }
, cacert ? pkgs.cacert
, racket-catalog ? stdenvNoCC.mkDerivation {
    name = "pkgs-all";
    buildInputs = [ racket ];
    builder = builtins.toFile "dump-catalogs.sh" ''
      $racket/bin/racket -N dump-catalogs $racket2nix/share/racket/pkgs/nix/dump-catalogs.rkt https://download.racket-lang.org/releases/6.12/catalog/ > $out
    '';
    inherit racket racket2nix;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1p8f4yrnv9ny135a41brxh7k740aiz6m41l67bz8ap1rlq2x7pgm";
  }
}:

(stdenvNoCC.mkDerivation rec {
  name = "racket2nix-default.nix";
  src = ./.;
  buildInputs = [ racket racket2nix ];
  phases = "unpackPhase installPhase";
  installPhase = ''
    racket -G ${racket2nix}/etc/racket -l- nix/racket2nix --catalog ${racket-catalog} ./nix > $out
  '';
}) // { inherit racket-catalog; }
