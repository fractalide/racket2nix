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

make test |& subfold test

# Allow running travis-test.sh on macOS while full racket is not yet available
if (( $(nix-instantiate --eval -E 'if (import ./nixpkgs.nix {}).racket.meta.available then 1 else 0') )); then
  nix-build --no-out-link -E 'with import ./nixpkgs.nix {}; callPackage ./. {}' |& subfold racket2nix.full-racket
fi
