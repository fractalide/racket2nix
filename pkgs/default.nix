{ pkgs ? import ../nixpkgs
, overlays ? []
, system ? builtins.currentSystem
, ...
}@args:

let
pkgsFn = args: args.pkgs ((removeAttrs args [ "pkgs" ]) // { overlays = [ (self: super: let racket2nix-pkgs = {
  racket-full = (args.pkgs (removeAttrs args [ "overlays" "pkgs" ])).racket;
  racket-minimal = self.callPackage ../racket-minimal {};
  racket = self.racket-minimal;

  racket2nix-stage0 = self.callPackage ../stage0.nix {};
  racket2nix-stage1 = self.callPackage ../stage1.nix {};
  racket2nix = self.racket2nix-stage0;
  inherit (self.callPackage ../build-racket.nix {})
    buildRacket buildRacketPackage buildRacketCatalog
    buildThinRacket buildThinRacketPackage;
}; in racket2nix-pkgs // { inherit racket2nix-pkgs; }) ] ++ args.overlays; });
makeOverridable = g: args: (g (args // { overlays = args.overlays ++ [
  (self: super: { overridePkgs = f: makeOverridable g (args // (f args)); })
]; }));
in
makeOverridable pkgsFn ({ inherit pkgs overlays system; } // args)
