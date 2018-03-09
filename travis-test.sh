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

make test | awk '
  BEGIN {
    current_scope=""
  }
  /^building \x27\/nix\/store\/.*[.]drv\x27/ {
    if(current_scope != "") {
      printf "travis_fold:end:%s\r", current_scope
    }
    current_scope=$0
    sub("building \x27/nix/store/", "", current_scope)
    sub("\x27.*", "", current_scope)
    printf "travis_fold:start:%s\r", current_scope
  }
  { print }
'
