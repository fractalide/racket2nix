let
  bootPkgs = import <nixpkgs> {};
  pinnedPkgs = bootPkgs.fetchFromGitHub {
    owner = "NixOS";
    repo = "nixpkgs-channels";
    rev = "5e5e57c5728722450091160b2b0dbf53a311b230";
    sha256 = "1dcs2rsfwf7fpypbdxbvxqyd7dl1sjd9xl7h77l89fklfrdwfsk7";
  };
in
import pinnedPkgs
