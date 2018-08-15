{ pkgs ? import ../nixpkgs {}
, racket2nix ? pkgs.callPackage ./.. {}
, buildRacket ? racket2nix.buildRacket
, catalog ? import ./catalog.nix {}
}:

rec {
  circular-subdeps = buildRacket { package = "a-depends-on-b"; inherit catalog; flat = false; };
  circular-subdeps-flat = circular-subdeps.override { flat = true; };
}
