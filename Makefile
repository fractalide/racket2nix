default: all

all: default.nix

RACKET2NIX_FILES=update-default.nix nix/info.rkt nix/racket2nix.rkt pkgs-nix

default.nix.in.timestamp: $(RACKET2NIX_FILES)
	nix-build update-default.nix --out-link default.nix.in
	touch $@

default.nix: default.nix.in.timestamp
	cat < default.nix.in > $@.new
	nix-build $@.new
	mv $@.new $@

pkgs-all:
	nix-build update-default.nix --out-link pkgs-all -A racket-catalog

test:
	nix-build test.nix --no-out-link 2>&1

.PHONY: test
