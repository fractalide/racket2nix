#! /usr/bin/env nix-shell
#! nix-shell --quiet -i bash -p bash coreutils gawk gnused

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

## Evaluate packages provided on the command line, if any, otherwise
## all packages in racket-packages.nix

if (( $# == 0)); then
  packages=($(nix-instantiate --eval -E  'builtins.concatStringsSep " "
    (builtins.attrNames (import ./racket-packages.nix {}))' | tr -d '"'))
else
  packages=("$@")
fi

i=1
for package in ${packages[@]}; do
  echo >&2 $((i++))/${#packages[@]} $package
  timeout 20m nix-build 2> >(sed -ue 's,/nix/store/.\{33\},,' | stdbuf -o0 gawk '
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

sort -u build-racket-install-check-overrides.txt{,.new} | grep -v '^$' > build-racket-install-check-overrides.txt.new2
rm build-racket-install-check-overrides.txt.new
mv build-racket-install-check-overrides.txt{.new2,}
