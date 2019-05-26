{ pkgs ? import ./pkgs {}
, callPackage ? pkgs.callPackage
, catalog ? ./catalog.rktd
}:

callPackage ({cacert, callPackageFull, nix, racket, runCommand}:
let
nix-command = nix;
bootstrap = name: extraArgs: let
  nix = runCommand "${name}.nix" {
    src = ./nix;
    buildInputs = [ cacert nix-command racket ];
    inherit extraArgs;
  } ''
    racket -N racket2nix $src/racket2nix.rkt $extraArgs --catalog ${catalog} $src > $out
  '';
  nixAttrs = callPackageFull nix {};
  out = if nixAttrs ? overrideAttrs then nixAttrs.overrideAttrs (oldAttrs: {
    name = "${name}";
    postInstall = "$out/bin/racket2nix --test";
    buildInputs = oldAttrs.buildInputs ++ [ nix-command ];
  }) else {};
in
  out // { inherit nix; };
in

(bootstrap "racket2nix-stage0" "") // {
  flat = bootstrap "racket2nix-stage0.flat" "--flat";
  thin = let inherit (bootstrap "racket2nix-stage0.thin" "--thin") nix; in
    ((callPackageFull ./racket-packages.nix {}).extend (import nix)).nix // { inherit nix; };
}) {}
