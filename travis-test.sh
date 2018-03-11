#! /usr/bin/env bash
set -e
set -u
set -o pipefail

printf 'travis_fold:start:catalog\r'
make pkgs-all
printf 'travis_fold:end:catalog\r'

printf 'travis_fold:start:racket2nix-stage0.prerequisites\r'
nix-shell stage0.nix --run true
printf 'travis_fold:end:racket2nix-stage0.prerequisites\r'

printf 'travis_fold:start:racket2nix\r'
make
printf 'travis_fold:end:racket2nix\r'
