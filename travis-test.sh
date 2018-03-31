#! /usr/bin/env bash
set -e
set -u
set -o pipefail

function subfold() {
  local prefix=$1
  awk '
    BEGIN {
      current_scope="'$prefix'"
      printf "travis_fold:start:%s\r", current_scope
    }
    /^building \x27\/nix\/store\/.*[.]drv\x27/ {
      if(current_scope != "") {
        printf "travis_fold:end:%s\r", current_scope
      }
      current_scope=$0
      sub("building \x27/nix/store/", "", current_scope)
      sub("\x27.*", "", current_scope)
      current_scope=current_scope ".." "'$prefix'"
      printf "travis_fold:start:%s\r", current_scope
    }
    { print }
    END {
      if(current_scope != "") {
        printf "travis_fold:end:%s\r", current_scope
      }
    }
  '
}

make pkgs-all |& subfold catalog

nix-shell stage0.nix --run true |& subfold racket2nix-stage0.prerequisites

make |& subfold racket2nix

## We need to build racket-doc-nix for (test.nix).pkgs below to be
## resolvable
nix-build --no-out-link test.nix -A racket-doc-nix |& subfold racket-doc-nix

# Allow running travis-test.sh on macOS while full racket is not yet available
if (( $(nix-instantiate --eval -E 'with ./nixpkgs.nix {};
          if (builtins.elem builtins.currentSystem racket.meta.platforms) then 1 else 0') )); then
  nix-build --no-out-link -E 'with ./nixpkgs.nix {}; callPackage ./. {}' |& subfold racket2nix.full-racket
fi
