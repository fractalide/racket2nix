{ pkgs ? import (import ../nixpkgs) {}
, system ? builtins.currentSystem
, racket-minimal ? pkgs.racket-minimal
, ...
}@args:

let
  nixpkgs = pkgs;
  inherit (nixpkgs) bash lib newScope racket;
  inherit (lib) makeScope;
in
makeScope newScope (self: {
  pkgs = self;
  callPackageFull = (makeScope self.newScope (fullself: nixpkgs // self //
    { pkgs = fullself; extend = fullself.overrideScope'; })).callPackage;
  extend = self.overrideScope';
  racket-full = racket;
  inherit racket-minimal;
  racket = self.racket-minimal;

  buildDrvs = name: buildInputs: derivation {
    inherit name buildInputs system;
    builder = bash + "/bin/bash";
    args = [ "-c" "echo -n > $out" ];
  };
  racket2nix-stage0 = self.callPackage ../stage0.nix {};
  racket2nix-stage1 = self.callPackage ../stage1.nix {};
  racket2nix = self.buildRacketPackage "racket2nix";
  inherit (self.callPackage ../build-racket.nix {})
    buildRacket buildRacketPackage buildRacketCatalog
    buildThinRacket buildThinRacketPackage;
})
