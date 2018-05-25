#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash findutils gawk git

set -e
set -u
set -o pipefail

read rev sha256 < <(
  git ls-remote github:NixOS/nixpkgs-channels |
  awk '/nixpkgs-unstable/ { print $1 }' |
  xargs nix-prefetch-git --no-deepClone https://github.com/NixOS/nixpkgs-channels.git |
  awk -F '"'  '
    /rev/ { rev = $4 }
    /sha256/ { sha256 = $4 }
    END { print rev, sha256 }'
)

tee nixpkgs.nix.new <<EOF
let
  bootPkgs = import <nixpkgs> {};
  pinnedPkgs = bootPkgs.fetchFromGitHub {
    owner = "NixOS";
    repo = "nixpkgs-channels";
    rev = "$rev";
    sha256 = "$sha256";
  };
in
import pinnedPkgs
EOF

mv nixpkgs.nix{.new,}
