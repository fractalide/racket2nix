default: all

all: default.nix

default.nix: Makefile racket2nix
	./racket2nix drracket | tee "$@"
