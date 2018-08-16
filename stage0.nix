{ pkgs ? import ./pkgs {}
, catalog ? ./catalog.rktd
}:

let
  inherit (pkgs) nix racket runCommand;
  stage0-nix = runCommand "racket2nix-stage0.nix" {
    src = ./nix;
    buildInputs = [ nix racket ];
  } ''
    racket -N racket2nix $src/racket2nix.rkt --catalog ${catalog} $src > $out
  '';
  stage0 = pkgs.callPackage stage0-nix { inherit racket; };
in
stage0 // { nix = stage0-nix; }
