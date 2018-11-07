default: racket2nix

racket2nix:
	nix-build --no-out-link

release:
	./support/utils/nix-build-travis-fold.sh -I racket2nix=$(shell pwd | xargs readlink -e) --no-out-link release.nix 2>&1 | sed -e 's/travis_.*\r//'

test:
	nix-build --no-out-link test.nix 2>&1

.PHONY: racket2nix test
