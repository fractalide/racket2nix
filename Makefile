default: racket2nix

racket2nix:
	nix-build --no-out-link

pkgs-all:
	nix-build --out-link pkgs-all -A racket-catalog

test:
	nix-build test.nix --no-out-link 2>&1

.PHONY: racket2nix test
