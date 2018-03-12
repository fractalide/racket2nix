default: racket2nix racket2nix-flat-nix

racket2nix:
	nix-build --no-out-link

racket2nix-flat-nix:
	nix-build --no-out-link -A racket2nix-flat-nix

pkgs-all:
	nix-build --out-link pkgs-all catalog.nix

test:
	nix-shell test.nix --run true 2>&1

test-flat:
	nix-build --no-out-link test.nix -A racket-doc-flat 2>&1

.PHONY: racket2nix racket2nix-flat-nix test test-flat
