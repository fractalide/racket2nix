#!/usr/bin/env bash

set -eou pipefail

cd "${BASH_SOURCE[0]%/*}"

# Avoid an error when evaluating the version:
# `path '/nix/store/wpwijvjhwjh6pg6n1r8khl1alzma2vm8-source.drv' is not valid`
nix-build --no-out-link nixpkgs > /dev/null

# Ugh eval to remove the quotes around the string
version=$(eval echo $(nix-instantiate --eval -E 'with import ./pkgs {}; racket-full.version'))

url=https://download.racket-lang.org/releases/$version/catalog/
hash=$(nix-hash --type sha256 --base32 --flat <(
  nix-shell -E 'with import ./pkgs {}; [ racket ]' --run "racket -N dump-catalogs nix/dump-catalogs.rkt $url"))

cat > release-catalog.json.new <<EOF
{
  "url": "$url",
  "outputHash": "$hash"
}
EOF

mv release-catalog.json.new release-catalog.json
