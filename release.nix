{ isTravis ? false
, pkgs ? import ./pkgs
}:

let
  inherit (pkgs {}) lib buildRacketPackage;
  racket2nixPath = relPath: "${builtins.toString <racket2nix>}/${relPath}";

  genJobs = pkgs: rec {
    api = {
      # buildRacket is tested by ./integration-tests
      # buildRacketCatalog is tested by ./integration-tests
      # buildRacketPackage is tested by ./test.nix
      override-racket-derivation = (buildRacketPackage ./nix).overrideRacketDerivation (oldAttrs: {});
      one-liner = {
        string = pkgs.callPackage ./. { package = "gui-lib"; };
        path = pkgs.callPackage ./. { package = ./nix; };
      };
    };
    pkgs-all = pkgs.callPackage (racket2nixPath "catalog.nix") {};
    racket2nix = pkgs.callPackage <racket2nix> {};
    tests = {
      inherit (pkgs.callPackage (racket2nixPath "test.nix") {}) light-tests heavy-tests;
    };
  };
in
  (genJobs (pkgs {})) //
  {
    latest-nixpkgs = genJobs (pkgs { pkgs = import <nixpkgs>; });
    x86_64-darwin = genJobs (pkgs { system = "x86_64-darwin"; }) // {
      latest-nixpkgs = genJobs (pkgs { pkgs = import <nixpkgs>; system = "x86_64-darwin"; });
    };
  } // lib.optionalAttrs (pkgs {}).racket-full.meta.available {
    racket-full = genJobs (pkgs { overlays = [ (self: super: { racket = self.racket-full; }) ]; });
  } // lib.optionalAttrs isTravis {
    stage0-nix-prerequisites = (pkgs {}).racket2nix-stage0.buildInputs;
    travisOrder = [ "pkgs-all" "stage0-nix-prerequisites" "racket2nix" "tests.light-tests"
                    "racket-full.racket2nix" "api" ];
  }
