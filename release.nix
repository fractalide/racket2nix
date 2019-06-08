{ isTravis ? false
, pkgs ? import ./pkgs
, callPackage ? (pkgs {}).callPackage
}:

callPackage ({bash, cacert, coreutils, diffutils, gnused, lib, nix, racket, racket2nix, runCommand}: let
  genJobs = pkgs: (pkgs.callPackage ({buildRacketPackage, callPackage, racket, racket2nix-stage1}: rec {
    api = {
      # buildRacket is tested by ./integration-tests
      # buildRacketCatalog is tested by ./integration-tests
      # buildRacketPackage is tested by ./test.nix
      override-racket-derivation = (buildRacketPackage ./nix).overrideRacketDerivation (oldAttrs: {});
      one-liner = {
        string = callPackage ./. { package = "gui-lib"; };
        path = callPackage ./. { package = ./nix; };
      };
    };
    pkgs-all = callPackage <racket2nix/catalog.nix> {};
    racket2nix = racket2nix-stage1;
    tests = {
      inherit (callPackage <racket2nix/test.nix> {}) light-tests;
    } // lib.optionalAttrs ((builtins.match ".*racket-minimal.*" racket.name) != null) {
      inherit (callPackage <racket2nix/test.nix> {}) all-checked-packages heavy-tests;
    };
  }) {});
in
  (genJobs (pkgs {})) //
  {
    racket-packages-updated = runCommand "racket-packages-updated" rec {
      src = <racket2nix>;
      inherit racket2nix;
      buildInputs = [ cacert racket2nix ];
    } ''
      set -e; set -u
      racket2nix --catalog $src/catalog.rktd > racket-packages.nix
      if ! diff -u $src/racket-packages.nix racket-packages.nix > $out; then
        echo racket-packages.nix has not been kept up-to-date, please regenerate and commit.
        echo missing changes:
        diff -u racket-packages.nix $src/racket-packages.nix
      fi
    '';
    racket2nix-overlay-updated = runCommand "racket2nix-overlay-updated" {
      src = builtins.filterSource (path: type: type != "symlink") <racket2nix>;
      buildInputs = builtins.attrValues { inherit bash cacert coreutils diffutils gnused nix racket; };
      preferLocalBuild = true;
      allowSubstitutes = false;
    } ''
      set -euo pipefail
      cp -a $src src
      chmod -R a+w src
      cd src
      bash ./update-racket2nix-overlay.sh
      if ! diff -Nur ./ $src | tee $out; then
        echo
        echo ERROR: Your tree is out of date. Please run ./update-racket2nix-overlay.sh before commit.
        exit 1
      fi
    '';
    latest-nixpkgs = genJobs (pkgs { pkgs = import <nixpkgs> {}; });
  } // lib.optionalAttrs isTravis {
    stage0-nix-prerequisites = (pkgs {}).racket2nix-stage0.buildInputs;
    travisOrder = [ "pkgs-all" "stage0-nix-prerequisites" "racket2nix" "tests.light-tests"
                    "racket-packages-updated" "racket2nix-overlay-updated"
                    "racket-full.racket2nix" "api.override-racket-derivation" ];
  }) {}
