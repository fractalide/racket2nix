#! /usr/bin/env nix-shell
#! nix-shell --pure -p bash cacert nix racket-minimal -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

./racket2nix --catalog catalog.rktd > racket-packages.nix.new
mv racket-packages.nix{.new,}
