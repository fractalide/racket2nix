#!/usr/bin/env bash

set -e
set -u

cd "${BASH_SOURCE[0]%/*}"

./nixpkgs/bump.sh
./bump-release-catalog.sh
./bump-live-catalog.sh
./update-catalog.sh
nix-shell update.nix -A racket-packages
