let
  bootPkgs = import <nixpkgs> { };
  bootFetchgit = bootPkgs.fetchgit;
  remotePkgs = bootFetchgit {
    url = "git://github.com/NixOS/nixpkgs-channels.git";
    rev = "a66ce38acea505c4b3bfac9806669d2ad8b34efa";
    sha256 = "1jrz6lkhx64mvm0h4gky9b6iaazivq69smppkx33hmrm4553dx5h";
  };
in
{ pkgs ? import remotePkgs { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.racket-minimal
, default-nix ? pkgs.callPackage ./generate-default.nix { inherit racket; }
, colordiff ? pkgs.colordiff
, racket-catalog ? default-nix.racket-catalog
}:

let attrs = rec {
  test-racket2nix = stdenvNoCC.mkDerivation {
    name = "test-racket2nix";
    src = ./.;
    phases = "unpackPhase buildPhase";
    buildPhase = ''
      echo output in $out
      echo
      diff -u default.nix ${default-nix} | tee $out | ${colordiff}/bin/colordiff
    '';
  };
  racket2nix = pkgs.callPackage (import ./.) { inherit racket; };
  racket-doc-nix = stdenvNoCC.mkDerivation {
    name = "racket-doc.nix";
    buildInputs = [ racket ];
    phases = "installPhase";
    installPhase = ''
      racket -G ${racket2nix}/etc/racket -l- nix/racket2nix --catalog ${racket-catalog} racket-doc > $out
    '';
  };
  racket-doc = pkgs.callPackage racket-doc-nix { inherit racket; };
};
in
attrs.racket-doc // attrs
