{ pkgs ? import ./pkgs {}
}:

let
inherit (pkgs) buildRacketPackage nix racket2nix-stage0 runCommand;

# Don't just build a flat package, build it with flat racket2nix.
buildRacketPackageFlat = package: (pkgs.overridePkgs (oldAttrs: {
  overlays = oldAttrs.overlays ++ [ (self: super: { racket2nix = super.racket2nix.flat; }) ];
})).buildRacket { inherit package; flat = true; };

testAndVerify = drv: drv.overrideAttrs (oldAttrs: {
  buildInputs = oldAttrs.buildInputs ++ [ nix verify ];
  postInstall = "$out/bin/racket2nix --test";
});

stage1 = (buildRacketPackage ./nix) // {
  flat = buildRacketPackageFlat ./nix;
};

verify = runCommand "verify-stage1.sh" {} ''
  set -e; set -u
  diff ${racket2nix-stage0.nix} ${stage1.nix} >> $out
  diff ${racket2nix-stage0.flat.nix} ${stage1.flat.nix} >> $out
'';

racket2nix-stage1 = (testAndVerify stage1).overrideAttrs (oldAttrs: {
  name = "racket2nix-stage1";
}) // {
  inherit (stage1) nix;
  flat = (testAndVerify stage1.flat).overrideAttrs (oldAttrs: {
    name = "racket2nix-stage1.flat";
  }) // { inherit (stage1.flat) nix; };
};
in
racket2nix-stage1
