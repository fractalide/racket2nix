{ pkgs ? import ./nixpkgs { }
, stdenvNoCC ? pkgs.stdenvNoCC
, nix ? pkgs.nix
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, racket2nix ? pkgs.callPackage ./. { inherit racket; }
, racket2nix-stage0 ? pkgs.callPackage ./stage0.nix { inherit racket; }
, colordiff ? pkgs.colordiff
, racket-catalog ? ./catalog.rktd
}:

let provided-racket = racket; in
let attrs = rec {
  inherit pkgs;
  inherit racket2nix;
  inherit racket2nix-stage0;
  generateNix = { catalog, extraArgs, package }: stdenvNoCC.mkDerivation {
    name = "${package}.nix";
    buildInputs = [ racket2nix nix ];
    phases = "installPhase";
    installPhase = ''
      racket2nix ${extraArgs} --catalog ${catalog} ${package} > $out
    '';
  };
  buildPackage = { catalog ? racket-catalog, racket ? provided-racket
                 , extraArgs ? "", package }:
    let
      nix = generateNix {
        inherit catalog extraArgs package;
      };
    in
      (pkgs.callPackage nix { inherit racket; }) // { inherit nix; };

  racket-doc = buildPackage { package = "racket-doc"; };
  racket-doc-nix = racket-doc.nix;
  racket-doc-flat = buildPackage { package = "racket-doc"; extraArgs = "--flat"; };
  racket-doc-flat-nix = racket-doc-flat.nix;
  typed-map-lib = buildPackage { package = "typed-map-lib"; };
  typed-map-lib-flat = buildPackage { package = "typed-map-lib"; extraArgs = "--flat"; };
  br-parser-tools-lib = buildPackage { package = "br-parser-tools-lib"; };
  br-parser-tools-lib-flat = buildPackage { package = "br-parser-tools-lib"; extraArgs = "--flat"; };
  light-tests = stdenvNoCC.mkDerivation {
    name = "light-tests";
    buildInputs = [ typed-map-lib typed-map-lib-flat br-parser-tools-lib br-parser-tools-lib-flat ];
    phases = "installPhase";
    installPhase = ''touch $out'';
  };
  heavy-tests = stdenvNoCC.mkDerivation {
    name = "heavy-tests";
    buildInputs = [ racket-doc racket-doc-flat ];
    phases = "installPhase";
    installPhase = ''touch $out'';
  };
};
in
attrs.light-tests // attrs
