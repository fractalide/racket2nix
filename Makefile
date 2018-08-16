default: racket2nix

racket2nix:
	nix-build --no-out-link

test:
	nix-build --no-out-link test.nix 2>&1

.PHONY: racket2nix test
