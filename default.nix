{ system ? builtins.currentSystem
, pkgs ? import ./pkgs { inherit system; }
, package ? null
, flat ? false
, catalog ? ./catalog.rktd
}:

let
  inherit (pkgs) buildEnv buildRacket nix nix-prefetch-git racket2nix-stage1;

  # We put the deps both in paths and buildInputs, so you can use this either as just
  # nix-shell -A racket2nix.buildEnv
  # and get the environment-variable-only environment, or you can use it as
  # nix-shell -p $(nix-build -A racket2nix.buildEnv)
  # and get the symlink tree environment

  racket2nix-env = buildEnv rec {
    name = "racket2nix-env";
    paths = [ nix nix-prefetch-git racket2nix-stage1 ];
    buildInputs = paths;
  };

  attrs = pkgs // {
    racket2nix = racket2nix-stage1;
    inherit racket2nix-env;
  };
in
if package == null then (attrs.racket2nix // attrs) else
buildRacket { inherit catalog package flat; }
