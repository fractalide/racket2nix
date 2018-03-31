{ pkgs ? import ./nixpkgs.nix { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, racket2nix ? pkgs.callPackage ./. { inherit racket; }
, racket2nix-stage0 ? pkgs.callPackage ./stage0.nix { inherit racket; }
, colordiff ? pkgs.colordiff
, racket-catalog ? pkgs.callPackage ./catalog.nix { inherit racket; }
}:

let attrs = rec {
  inherit pkgs;
  inherit racket2nix;
  inherit racket2nix-stage0;
  racket-doc-nix = { extraArgs ? ""} : stdenvNoCC.mkDerivation {
    name = "racket-doc.nix";
    buildInputs = [ racket2nix ];
    phases = "installPhase";
    installPhase = ''
      racket2nix ${extraArgs} --catalog ${racket-catalog} racket-doc > $out
    '';
  };
  racket-doc = pkgs.callPackage (racket-doc-nix {}) { inherit racket; };
  racket-doc-flat-nix = racket-doc-nix { extraArgs = "--flat"; };
  racket-doc-flat = pkgs.callPackage racket-doc-flat-nix { inherit racket; };
};
in
attrs.racket-doc // attrs
