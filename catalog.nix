{ pkgs ? import <nixpkgs> { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.racket-minimal
, cacert ? pkgs.cacert
}:

stdenvNoCC.mkDerivation {
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
}
