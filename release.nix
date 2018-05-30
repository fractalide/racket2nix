{ isTravis ? false
}:

let
  racket2nixPath = relPath: "${builtins.toString <racket2nix>}/${relPath}";
  nixpkgs = import (racket2nixPath "nixpkgs.nix") {};
in
{
  pkgs-all = import (racket2nixPath "catalog.nix") {};
  racket2nix = import <racket2nix> {};
  racket2nix-flat-nix = (import <racket2nix> {}).racket2nix-flat-nix;
  test = import (racket2nixPath "test.nix") {};
} // nixpkgs.lib.optionalAttrs nixpkgs.racket.meta.available {
  racket2nix-full-racket = nixpkgs.callPackage <racket2nix> {};
} // nixpkgs.lib.optionalAttrs isTravis {
  stage0-nix-prerequisites = (import (racket2nixPath "stage0.nix") {}).buildInputs;
  travisOrder = [ "pkgs-all" "stage0-nix-prerequisites" "racket2nix" "racket2nix-flat-nix" "test" "racket2nix-full-racket" ];
}
