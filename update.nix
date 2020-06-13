{ pkgs ? import ./pkgs {}
, callPackage ? pkgs.callPackage
, test ? callPackage ./test.nix {}
}:

callPackage ({mkShell, coreutils, findutils, gawk, gnugrep, gnused, nix}:
{
  top100-checked-packages = mkShell {
    name = "top100-checked-packages";
    nativeBuildInputs = [ coreutils findutils gawk gnugrep gnused nix ];
    shellHook = ''
      # Rank checked packages by roughly how many of the other checked packages transitively depend
      # on them, grab the top 100

      set -euo pipefail
      nix-instantiate test.nix -A all-checked-packages |
        xargs nix-store --query --graph |
        awk '$1 ~ /racket-minimal-.*drv/ {print $1}' |
        grep -Ff build-racket-install-check-overrides.txt |
        sort | uniq -c | sort -rn | head -n 100 |
        sed -ne 's/.*racket-minimal-[0-9.]*-\([^.]*\)[.]drv"/\1/p' \
        > top100-checked-packages.txt.new.$$
      mv top100-checked-packages.txt{.new.$$,}
      exit 0
    '';
  };
}) {}
