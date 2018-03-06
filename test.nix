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
}:

stdenvNoCC.mkDerivation rec {
  name = "test-racket2nix";
  src = ./.;
  phases = "unpackPhase buildPhase";
  buildPhase = ''
    echo output in $out
    echo
    diff -u default.nix ${default-nix} | tee $out | ${colordiff}/bin/colordiff
  '';
}
