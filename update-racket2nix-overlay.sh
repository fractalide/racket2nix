#! /usr/bin/env nix-shell
#! nix-shell --pure -p bash cacert gnused nix -i bash

set -eu

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

OUTPUT_FILE=build-racket-racket2nix-overlay.nix

if (( $# > 0 )) && [[ $1 == --inside-nix-derivation ]]; then
  racket2nix=racket2nix
else
  racket2nix=./racket2nix
fi

$racket2nix --thin ./nix |
  sed -e 's,src =.*,src = ./nix;,p' -e '/src =/,/}/d' \
  > $OUTPUT_FILE.new
mv $OUTPUT_FILE{.new,}
