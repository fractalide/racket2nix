{ pkgs ? import ../pkgs {}
}:

let
inherit (pkgs) buildRacket buildRacketCatalog racket racket2nix;
attrs = rec {
  catalog = buildRacketCatalog [ ./a-depends-on-b ./b-depends-on-c ./c-depends-on-b ];
  circular-subdeps = buildRacket { package = "a-depends-on-b"; inherit catalog; flat = false; };
  circular-subdeps-flat = circular-subdeps.override { flat = true; };
}; in

attrs // { inherit attrs; }
