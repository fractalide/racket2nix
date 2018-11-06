#! /usr/bin/env nix-shell
#! nix-shell -p bash racket-minimal nix-prefetch-git -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

echo NOTE: nix-prefetch-git will use your ${XDG_RUNTIME_DIR:-${TMP:-/tmp}}
echo NOTE: to download some pretty large git repos. Make sure you have
echo NOTE: hundreds of megabytes of space.

./racket2nix --catalog $(nix-build catalog.nix) --export-catalog |
  racket -e '(pretty-write (read))' > catalog.rktd.new
mv catalog.rktd.new catalog.rktd
