default: all

all: default.nix

default.nix: Makefile racket2nix nix/racket2nix.rkt
	./racket2nix drracket | tee "$@"
