#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash findutils gawk git

set -e
set -u
set -o pipefail

git ls-remote github:NixOS/nixpkgs-channels |
  awk '/nixpkgs-unstable/ { print $1 }' |
  xargs nix-prefetch-git --no-deepClone https://github.com/NixOS/nixpkgs-channels.git |
  awk -F '"'  '/rev/ { rev = $4 } /sha256/ { sha256 = $4 } END { printf "let\n  bootPkgs = import <nixpkgs> { };\n  pinnedPkgs = bootPkgs.fetchFromGitHub {\n    owner = \"NixOS\";\n    repo = \"nixpkgs-channels\";\n    rev = \"%s\";\n    sha256 = \"%s\";\n  };\nin\nimport pinnedPkgs\n", rev, sha256 }' |
  tee nixpkgs.nix.new
mv nixpkgs.nix{.new,}
