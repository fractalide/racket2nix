default: racket2nix

racket2nix:
	nix-build --no-out-link

release:
	./support/utils/nix-build-travis-fold.sh -I racket2nix=$(PWD) --no-out-link release.nix
	echo

test:
	nix-build --no-out-link test.nix 2>&1

.PHONY: racket2nix test
