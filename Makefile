default: racket2nix

racket2nix:
	nix-build --no-out-link

pkgs-all:
	nix-build --out-link pkgs-all catalog.nix

test:
	nix-build --no-out-link test.nix 2>&1

.PHONY: racket2nix racket2nix-flat-nix test test-flat
