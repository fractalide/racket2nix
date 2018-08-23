{ pkgs ? import ./pkgs {}
}:

let
inherit (pkgs) buildRacket nix nix-prefetch-git racket2nix-stage0 runCommand;

# Don't just build a flat package, build it with flat racket2nix.
buildRacketFlat = { ... }@args: (pkgs.overridePkgs (oldAttrs: {
  overlays = oldAttrs.overlays ++ [ (self: super: { racket2nix = super.racket2nix.flat; }) ];
})).buildRacket (args // { flat = true; });

attrOverrides = oldAttrs: {
  buildInputs = oldAttrs.buildInputs ++ [ verify ];
  propagatedBuildInputs = (oldAttrs.propagatedBuildInputs or []) ++ [ nix.out nix-prefetch-git ];
  postInstall = "$out/bin/racket2nix --test";
};

stage1 = buildRacket { package = ./nix; attrOverrides = (oldAttrs: attrOverrides oldAttrs // {
  pname = "racket2nix-stage1";
}); } // {
  flat = buildRacketFlat { package = ./nix; attrOverrides = (oldAttrs: attrOverrides oldAttrs // {
    pname = "racket2nix-stage1.flat";
  }); };
};

verify = runCommand "verify-stage1.sh" {} ''
  set -e; set -u
  diff ${racket2nix-stage0.nix} ${stage1.nix} >> $out
  diff ${racket2nix-stage0.flat.nix} ${stage1.flat.nix} >> $out
'';

in
stage1
