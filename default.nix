{ system ? builtins.currentSystem
, pkgs ? import ./pkgs { inherit system; }
, package ? null
, flat ? false
, catalog ? ./catalog.rktd
}:

let
  inherit (pkgs) buildRacket nix nix-prefetch-git racket2nix-stage1 stdenvNoCC;
  racket2nix-env = stdenvNoCC.mkDerivation {
    phases = [];
    buildInputs = [ nix nix-prefetch-git racket2nix-stage1 ];
    name = "racket2nix-env";
  };
  attrs = pkgs // {
    racket2nix = racket2nix-stage1;
    inherit racket2nix-env;
  };
in
if package == null then (attrs.racket2nix // attrs) else
buildRacket { inherit catalog package flat; }
