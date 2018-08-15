{ pkgs ? import ../pkgs {}
, racket2nix ? pkgs.racket2nix
, catalog ? ../catalog.rktd
}:

pkgs.runCommand "catalog.rktd" {
  buildInputs = [ racket2nix ];
  src = ./.;
  inherit catalog;
} ''
  cd $src
  racket2nix --catalog catalog.rktd.in --catalog $catalog --export-catalog a-depends-on-b |
    sed -e "s,\"./,\"$src/,g" > $out
''
