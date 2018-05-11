#! /usr/bin/env nix-shell
#! nix-shell -p bash racket-minimal nix-prefetch-git -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

./racket2nix --catalog $(nix-build catalog.nix) --export-catalog > catalog.rktd.new
mv catalog.rktd.new catalog.rktd
