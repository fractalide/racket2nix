let
  bootPkgs = import <nixpkgs> { };
  pinnedPkgs = bootPkgs.fetchFromGitHub {
    owner = "NixOS";
    repo = "nixpkgs-channels";
    rev    = "9d0b6b9dfc92a2704e2111aa836f5bdbf8c9ba42";
    sha256 = "096r7ylnwz4nshrfkh127dg8nhrcvgpr69l4xrdgy3kbq049r3nb";
  };
in
import pinnedPkgs
