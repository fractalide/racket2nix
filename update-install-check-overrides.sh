#! /usr/bin/env nix-shell
#! nix-shell --quiet -i bash -p bash coreutils gawk gnused

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

packages=($(nix-instantiate --eval -E  'builtins.concatStringsSep " " (builtins.attrNames (import ./racket-packages.nix {}))' | tr -d '"'))

i=1
for package in ${packages[@]}; do
  echo >&2 $((i++))/${#packages[@]} $package
  nix-build 2> >(sed -ue 's,/nix/store/.\{33\},,' | stdbuf -o0 gawk '
    BEGIN { start = systime() }
    { printf "\r%s %s\033[K", strftime("%H:%M:%S", systime() - start, 1), substr($0, 1, 68) }
    END { printf "\r\033[K" }
  ' >&2) \
    --no-build-output -E '{package}:
    (import ./. { inherit package; }).overrideRacketDerivation (oldAttrs: { doInstallCheck = true; })' \
  --argstr package $package | xargs nix-store --read-log | sed -ne '/running install tests/,$p' |
  grep -A 1 'tests passed' >&2 &&
  echo $package
done > build-racket-install-check-overrides.txt.new

mv build-racket-install-check-overrides.txt{.new,}
