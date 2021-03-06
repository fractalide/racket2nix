#! /usr/bin/env nix-shell
#! nix-shell -p bash nix-prefetch-git -i bash

set -e
set -u

SCRIPT_NAME=${BASH_SOURCE[0]##*/}
cd "${BASH_SOURCE[0]%${SCRIPT_NAME}}"

echo NOTE: nix-prefetch-git will use your ${XDG_RUNTIME_DIR:-${TMP:-/tmp}}
echo NOTE: to download some pretty large git repos. Make sure you have
echo NOTE: hundreds of megabytes of space.

catalog=$(nix-build --no-out-link catalog.nix)
unset GIT_DIR GIT_WORK_TREE  # These interfere with nix-prefetch-git
./racket2nix --catalog $catalog --cache-catalog catalog.rktd --sanitize-catalog --export-catalog > catalog.rktd.new
mv catalog.rktd.new catalog.rktd
