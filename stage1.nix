{ pkgs ? import ./pkgs {}
, cacert ? pkgs.cacert
}:

let
inherit (pkgs) buildRacket nix nix-prefetch-git racket2nix-stage0 runCommand;

# Don't just build a flat package, build it with flat racket2nix.
buildRacketFlat = { ... }@args: (pkgs.overridePkgs (oldAttrs: {
  overlays = oldAttrs.overlays ++ [ (self: super: { racket2nix = super.racket2nix-stage0.flat; }) ];
})).buildRacket (args // { flat = true; });

buildThin = { ... }@args: (pkgs.overridePkgs (oldAttrs: {
  overlays = oldAttrs.overlays ++ [ (self: super: { racket2nix = super.racket2nix-stage0.thin; }) ];
})).buildThinRacket args;

attrOverrides = oldAttrs: {
  buildInputs = oldAttrs.buildInputs ++ [ verify ];
  propagatedBuildInputs = (oldAttrs.propagatedBuildInputs or []) ++ [ nix.out nix-prefetch-git ];
  postInstall = "$out/bin/racket2nix --test";
};

stage1 = buildRacket { package = ./nix; pname = "racket2nix-stage1"; inherit attrOverrides; } // {
  flat = buildRacketFlat { package = ./nix; pname = "racket2nix-stage1.flat"; inherit attrOverrides; };
  thin = buildThin { package = ./nix; inherit attrOverrides; };
};

verify = runCommand "verify-stage1.sh" {
  buildInputs = [ cacert ];
} ''
  set -e; set -u
  diff ${racket2nix-stage0.nix} ${stage1.nix} >> $out
  diff ${racket2nix-stage0.flat.nix} ${stage1.flat.nix} >> $out
  diff ${racket2nix-stage0.thin.nix} ${stage1.thin.nix} >> $out
'';

in
stage1
