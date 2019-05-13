#! /usr/bin/env nix-shell
#! nix-shell --pure -p bash cacert coreutils nix racket-minimal -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

out=$(mktemp racket-packages.nix.XXXXXX)
./racket2nix --catalog catalog.rktd > $out
mv $out racket-packages.nix
