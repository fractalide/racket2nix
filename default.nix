{ system ? builtins.currentSystem
, pkgs ? import ./pkgs { inherit system; }
, package ? null
, flat ? false
, catalog ? ./catalog.rktd
}:

let
inherit (pkgs) buildEnv buildRacket nix nix-prefetch-git racket racket2nix-stage0 stdenvNoCC;
attrs = rec {
  inherit buildRacket;
  racket2nix-stage1 = pkgs.callPackage ./stage1.nix {};
  racket2nix-stage1-nix = racket2nix-stage1.nix;
  racket2nix = racket2nix-stage1

  racket2nix-flat-stage0 = racket2nix-stage0.flat;
  racket2nix-flat-stage0-nix = racket2nix-stage0.flat.nix;
  racket2nix-flat-stage1-nix = racket2nix-stage1.flat.nix;
  racket2nix-flat-nix = racket2nix-flat-stage1-nix;

  racket2nix-env = stdenvNoCC.mkDerivation {
    phases = [];
    buildInputs = [ nix nix-prefetch-git racket2nix ];
    name = "racket2nix-env";
  };
};
in
if package == null then (attrs.racket2nix // attrs) else
buildRacket { inherit catalog package flat; }
