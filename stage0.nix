{ pkgs ? import ./nixpkgs.nix { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, racket-catalog ? pkgs.callPackage ./catalog.nix { inherit racket; }
}:

let attrs = rec {
  racket2nix-stage0-nix = stdenvNoCC.mkDerivation {
    name = "racket2nix-stage0.nix";
    src = ./nix;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      racket -N racket2nix ./racket2nix.rkt --catalog ${racket-catalog} ../nix > $out
    '';
  };
  racket2nix-stage0 = (pkgs.callPackage racket2nix-stage0-nix { inherit racket; }).racketDerivation.override { src = ./nix; };
};
in
attrs.racket2nix-stage0 // attrs
