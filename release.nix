{ isTravis ? false
}:

let
  racket2nixPath = relPath: "${builtins.toString <racket2nix>}/${relPath}";
  pinned-nixpkgs-fn = import (racket2nixPath "nixpkgs");
  nixpkgs = pinned-nixpkgs-fn {};
  genJobs = pkgs: rec {
    pkgs-all = import (racket2nixPath "catalog.nix") { inherit pkgs; };
    racket2nix = import <racket2nix> { inherit pkgs; };
    racket2nix-flat-nix = racket2nix.racket2nix-flat-nix;
    test = import (racket2nixPath "test.nix") { inherit pkgs;};
  } // pkgs.lib.optionalAttrs pkgs.racket.meta.available {
    racket2nix-full-racket = pkgs.callPackage <racket2nix> {};
  };
in
  (genJobs nixpkgs) //
  {
    latest-nixpkgs = genJobs (import <nixpkgs> {});
    x86_64-darwin = genJobs (pinned-nixpkgs-fn { system = "x86_64-darwin"; }) // {
      latest-nixpkgs = genJobs (import <nixpkgs> { system = "x86_64-darwin"; });
    };
  } // nixpkgs.lib.optionalAttrs isTravis {
    stage0-nix-prerequisites = (import (racket2nixPath "stage0.nix") {}).buildInputs;
    travisOrder = [ "pkgs-all" "stage0-nix-prerequisites" "racket2nix" "racket2nix-flat-nix" "test" "racket2nix-full-racket" ];
  }
