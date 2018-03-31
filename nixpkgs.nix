let
  bootPkgs = import <nixpkgs> { };
  pinnedPkgs = bootPkgs.fetchFromGitHub {
    owner = "NixOS";
    repo = "nixpkgs-channels";
    rev = "a66ce38acea505c4b3bfac9806669d2ad8b34efa";
    sha256 = "1jrz6lkhx64mvm0h4gky9b6iaazivq69smppkx33hmrm4553dx5h";
  };
in
import pinnedPkgs
