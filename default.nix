{ system ? builtins.currentSystem
, overlays ? []
, pkgs ? import ./pkgs { inherit overlays system; }
, package ? null
, flat ? false
, catalog ? ./catalog.rktd
}:

let
  inherit (pkgs) buildRacket racket2nix-stage1;
  attrs = pkgs // {
    racket2nix = racket2nix-stage1;
  };
in
if package == null then (attrs.racket2nix // attrs) else
buildRacket { inherit catalog package flat; }
