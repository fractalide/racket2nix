#!/usr/bin/env bash

NAME=live-catalog
URL_BASE=https://pkgs.racket-lang.org/pkgs-all

set -eou pipefail

cd "${BASH_SOURCE[0]%/*}"

# Avoid an error when evaluating the version:
# `path '/nix/store/wpwijvjhwjh6pg6n1r8khl1alzma2vm8-source.drv' is not valid`
nix-build --no-out-link nixpkgs > /dev/null

# Ugh eval to remove the quotes around the string
version=$(eval echo $(nix-instantiate --eval -E 'with import ./pkgs {}; racket-full.version'))

save_url=https://web.archive.org/save/$URL_BASE?version=$version
save_headers=$(curl -sfiI "$save_url")
snapshot_url=$(while read -r header value; do
  if [[ $header == location: ]]; then echo "${value%$'\r'}"; exit 0; fi;
done <<< "$save_headers"; exit 1)
sha256=$(nix-prefetch-url --name $NAME --type sha256 "$snapshot_url")

cat > live-catalog.json.new <<EOF
{
  "name": "$NAME",
  "url": "$snapshot_url",
  "sha256": "$sha256"
}
EOF

mv live-catalog.json.new live-catalog.json
