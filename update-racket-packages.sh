#! /usr/bin/env nix-shell
#! nix-shell --pure -p bash cacert coreutils nix -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

out=$(mktemp racket-packages.nix.XXXXXX)
racket2nix=$(nix-build --no-out-link --argstr package racket2nix)
$racket2nix/bin/racket2nix --catalog catalog.rktd > $out
mv $out racket-packages.nix
