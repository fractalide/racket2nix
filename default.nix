{ system ? builtins.currentSystem
, overlays ? []
, pkgs ? import ./pkgs { inherit overlays system; }
, buildRacketPackage ? pkgs.buildRacketPackage
, buildThinRacket ? pkgs.buildThinRacket
, lib ? pkgs.lib
, package ? null
, pname ? null
}:

if package == null then (pkgs.racket2nix // pkgs)
else if builtins.isString package then buildRacketPackage package
else buildThinRacket ({ inherit package; } //
  lib.optionalAttrs (builtins.isString pname) { inherit pname; })
