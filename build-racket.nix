{ pkgs ? import ./nixpkgs.nix { }
, lib ? pkgs.lib
, stdenvNoCC ? pkgs.stdenvNoCC
, nix-prefetch-git ? pkgs.nix-prefetch-git
, catalog ? pkgs.callPackage ./catalog.nix { inherit racket; }
, racket ? pkgs.callPackage ./racket-minimal.nix { }
, racket2nix ? pkgs.callPackage ./stage0.nix { inherit racket; }
, package ? null
}:

let
  isStoreSubPath = path:
    let storePrefix = builtins.substring 0 (builtins.stringLength builtins.storeDir);
    in (storePrefix path) == builtins.storeDir;
  stripHash = path:
    let
      storeStripped = lib.removePrefix "/" (lib.removePrefix builtins.storeDir path);
      finalLength = (builtins.stringLength storeStripped) - 33;
    in
      builtins.substring 33 finalLength storeStripped;
  attrs = rec {
    buildRacketNix = { flat, package}:
    stdenvNoCC.mkDerivation {
      name = "racket-package.nix";
      outputs = [ "out" "src" ];
      buildInputs = [ racket2nix nix-prefetch-git ];
      phases = "installPhase";
      flatArg = lib.optionalString flat "--flat";
      installPhase = ''
        mkdir $src
        if (( ${if isStoreSubPath package then "1" else "0"} )); then
          packageName=$src/${baseNameOf (stripHash package)}
          cp -a ${package} $packageName
        else
          packageName=${package}
        fi
        racket2nix $flatArg --catalog ${catalog} $packageName > $out
      '';
    };
    buildRacket = lib.makeOverridable ({ flat ? false, package }:
      let nix = buildRacketNix { inherit flat package; };
      in (pkgs.callPackage nix { inherit racket; }) // { inherit nix; }
    );
  };
in
if package != null then attrs.buildRacket { inherit package; } else attrs
