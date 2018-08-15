{ pkgs ? import ../pkgs {}
, catalog ? import ./catalog.nix {}
}:

let
inherit (pkgs) buildRacket racket racket2nix;
attrs = rec {
  circular-subdeps = buildRacket { package = "a-depends-on-b"; inherit catalog; flat = false; };
  circular-subdeps-flat = circular-subdeps.override { flat = true; };
}; in

attrs // { inherit attrs; }
