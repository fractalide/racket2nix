#!/usr/bin/env nix-shell
#! nix-shell --quiet -p bash gawk git nix -i bash

set -euo pipefail

BASE_URL=https://github.com/NixOS/nixpkgs-channels
DEFAULT_REV=refs/heads/nixpkgs-unstable
NAME=source

cd "$(dirname "${BASH_SOURCE[0]}")"

rev=${1:-$DEFAULT_REV}

if (( ${#rev} != 40 )); then
  rev=$(git ls-remote $BASE_URL "$rev" | awk '$2 == "'"$rev"'" { print $1 }')
fi

url=$BASE_URL/archive/$rev.tar.gz
sha256=$(nix-prefetch-url --unpack --name $NAME "$url")
cat > default.json.new <<EOF
{
  "name": "$NAME",
  "url": "$url",
  "sha256": "$sha256",
  "unpack": true
}
EOF

mv default.json{.new,}
