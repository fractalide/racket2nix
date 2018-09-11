{ pkgs ? import ./pkgs {}
, catalog ? ./catalog.rktd
}:

let
inherit (pkgs) nix racket runCommand;
nix-command = nix;
bootstrap = name: extraArgs: let
  nix = runCommand "${name}.nix" {
    src = ./nix;
    buildInputs = [ nix-command racket ];
    inherit extraArgs;
  } ''
    racket -N racket2nix $src/racket2nix.rkt $extraArgs --catalog ${catalog} $src > $out
  '';
  nixAttrs = pkgs.callPackage nix {};
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
    ((pkgs.callPackage ./racket-packages.nix {}).extend (import nix)).nix // { inherit nix; };
}
