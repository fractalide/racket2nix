#! /usr/bin/env nix-shell
#! nix-shell --quiet -i bash -p bash

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

nix-build --no-out-link ./nixpkgs  # So that nix-build-travis-fold can evaluate release.nix
./support/utils/nix-build-travis-fold.sh -I racket2nix="$(pwd | xargs readlink -e)" --no-out-link release.nix "$@" |&
  sed -e 's/travis_.*\r//'
