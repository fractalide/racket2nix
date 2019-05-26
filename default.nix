{ system ? builtins.currentSystem
, pkgs ? import ./pkgs { inherit system; }
, callPackage ? pkgs.callPackage
, package ? null
, pname ? null
}:

callPackage ({buildRacketPackage, buildThinRacket, lib, racket2nix}:
if package == null then (racket2nix // pkgs)
else if builtins.isString package then buildRacketPackage package
else buildThinRacket ({ inherit package; } //
  lib.optionalAttrs (builtins.isString pname) { inherit pname; })) {}
