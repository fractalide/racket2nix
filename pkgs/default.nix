{ pkgs ? import ../nixpkgs
, overlays ? []
, system ? builtins.currentSystem
, ...
}@args:

pkgs (args // { overlays = [ (self: super: let racket2nix-pkgs = {
  racket-full = (pkgs (removeAttrs args [ "overlays" ])).racket;
  racket-minimal = self.callPackage ../racket-minimal {};
  racket = self.racket-minimal;

  racket2nix-stage0 = self.callPackage ../stage0.nix {};
  racket2nix = self.racket2nix-stage0;
  inherit (self.callPackage ../build-racket.nix {}) buildRacket buildRacketPackage;
}; in racket2nix-pkgs // { inherit racket2nix-pkgs; }) ] ++ overlays; })
