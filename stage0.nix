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
  out = (pkgs.callPackage nix {}).overrideAttrs (oldAttrs: {
    name = "${name}";
    postInstall = "$out/bin/racket2nix --test";
    buildInputs = oldAttrs.buildInputs ++ [ nix-command ];
  });
in
  out // { inherit nix; };
in

(bootstrap "racket2nix-stage0" "") // {
  flat = bootstrap "racket2nix-stage0.flat" "--flat";
}
