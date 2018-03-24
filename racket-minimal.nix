{ pkgs ? import <stdenv> {}
, stdenv ? pkgs.stdenv
, libiconv ? pkgs.libiconv
}:

if stdenv.isDarwin then
  pkgs.racket-minimal.overrideDerivation (drv: {
    buildInputs = drv.buildInputs ++ [ libiconv ];
  })
else
pkgs.racket-minimal
