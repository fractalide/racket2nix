{ pkgs ? import ../pkgs {}
, racket2nix ? pkgs.racket2nix
, buildRacket ? pkgs.buildRacket
, catalog ? import ./catalog.nix {}
, racket ? pkgs.racket
}:

let attrs = rec {
  circular-subdeps = buildRacket { package = "a-depends-on-b"; inherit catalog; flat = false; };
  circular-subdeps-flat = circular-subdeps.override { flat = true; };
}; in

attrs // { inherit attrs; }
