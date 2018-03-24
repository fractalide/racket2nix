#! /usr/bin/env bash
set -e
set -u
set -o pipefail

printf 'travis_fold:start:racket2nix-stage0.prerequisites\r'
nix-shell stage0.nix --run true
printf 'travis_fold:end:racket2nix-stage0.prerequisites\r'

printf 'travis_fold:start:racket2nix\r'
make
printf 'travis_fold:end:racket2nix\r'

## We need to build racket-doc-nix for (test.nix).pkgs below to be
## resolvable
printf 'travis_fold:start:racket-doc-nix\r'
nix-build --no-out-link test.nix -A racket-doc-nix
printf 'travis_fold:end:racket-doc-nix\r'

# Allow running travis-test.sh on macOS while full racket is not yet available
if (( $(nix-instantiate --eval -E 'with (import ./test.nix {}).pkgs;
          if (builtins.elem builtins.currentSystem racket.meta.platforms) then 1 else 0') )); then
  printf 'travis_fold:start:racket2nix.full-racket\r'
    nix-build --no-out-link -E 'with (import ./test.nix {}).pkgs; callPackage ./. {}'
  printf 'travis_fold:end:racket2nix.full-racket\r'
fi
