#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

./support/utils/nix-build-travis-fold.sh -I racket2nix="$(pwd | xargs readlink -e)" --no-out-link release.nix "$@" |&
  sed -e 's/travis_.*\r//'
