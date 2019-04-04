{ system ? builtins.currentSystem
, overlays ? []
, pkgs ? import ./pkgs { inherit overlays system; }
, package ? null
, pname ? null
}:

let
  inherit (pkgs) buildRacketPackage buildThinRacket lib racket2nix-stage1;
  attrs = pkgs // {
    racket2nix = racket2nix-stage1;
  };
in
if package == null then (attrs.racket2nix // attrs)
else if builtins.isString package then buildRacketPackage package
else buildThinRacket ({ inherit package; } //
  lib.optionalAttrs (builtins.isString pname) { inherit pname; })
