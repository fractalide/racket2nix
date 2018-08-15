{ pkgs ? import ../nixpkgs {}
, racket2nix ? pkgs.callPackage ./.. { inherit racket; }
, buildRacket ? racket2nix.buildRacket
, catalog ? import ./catalog.nix {}
, racket ? pkgs.callPackage ../racket-minimal.nix {}
}:

let attrs = rec {
  circular-subdeps = buildRacket { package = "a-depends-on-b"; inherit catalog; flat = false; };
  circular-subdeps-flat = circular-subdeps.override { flat = true; };
}; in

attrs // { inherit attrs; }
