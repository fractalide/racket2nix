default: all

all: default.nix

default.nix: info.rkt Makefile racket2nix
	./racket2nix <"$<" | tee "$@"
