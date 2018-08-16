{ pkgs ? import ./pkgs {}
}:

let
inherit (pkgs) buildEnv buildRacketPackage nix nix-prefetch-git racket2nix-stage0 runCommand;

# Don't just build a flat package, build it with flat racket2nix.
buildRacketPackageFlat = package: (pkgs.overridePkgs (oldAttrs: {
  overlays = oldAttrs.overlays ++ [ (self: super: { racket2nix = super.racket2nix.flat; }) ];
})).buildRacket { inherit package; flat = true; };

addAttrs = drv: drv.overrideAttrs (oldAttrs: {
  buildInputs = oldAttrs.buildInputs ++ [ nix verify ];
  postInstall = "$out/bin/racket2nix --test";

  # We put the deps both in paths and buildInputs, so you can use this either as just
  # nix-shell -A racket2nix.buildEnv
  # and get the environment-variable-only environment, or you can use it as
  # nix-shell -p $(nix-build -A racket2nix.buildEnv)
  # and get the symlink tree environment

  buildEnv = buildEnv rec {
    name = "${drv.name}-env";
    paths = [ nix nix-prefetch-git drv ];
    buildInputs = paths;
  };
});

stage1 = (buildRacketPackage ./nix) // {
  flat = buildRacketPackageFlat ./nix;
};

verify = runCommand "verify-stage1.sh" {} ''
  set -e; set -u
  diff ${racket2nix-stage0.nix} ${stage1.nix} >> $out
  diff ${racket2nix-stage0.flat.nix} ${stage1.flat.nix} >> $out
'';

racket2nix-stage1 = (addAttrs stage1).overrideAttrs (oldAttrs: {
  name = "racket2nix-stage1";
}) // {
  inherit (stage1) nix;
  flat = (addAttrs stage1.flat).overrideAttrs (oldAttrs: {
    name = "racket2nix-stage1.flat";
  }) // { inherit (stage1.flat) nix; };
};
in
racket2nix-stage1
