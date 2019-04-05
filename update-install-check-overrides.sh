#! /usr/bin/env nix-shell
#! nix-shell --quiet -i bash -p bash

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

packages=($(nix-instantiate --eval -E  'builtins.concatStringsSep " " (builtins.attrNames (import ./racket-packages.nix {}))' | tr -d '"'))

i=1
for package in ${packages[@]}; do
  echo >&2 $((i++))/${#packages[@]} $package
  nix-build --no-build-output --quiet -E '{package}:
    (import ./. { inherit package; }).overrideRacketDerivation (oldAttrs: { doInstallCheck = true; })' \
  --argstr package $package | xargs nix-store --read-log | sed -ne '/running install tests/,$p' |
  grep -A 1 'tests passed' >&2 &&
  echo $package
done > build-racket-install-check-overrides.txt.new

mv build-racket-install-check-overrides.txt{.new,}
