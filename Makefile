default: all

all: default.nix

default.nix: raco.out raco2nix Makefile
	./raco2nix <"$<" | tee "$@"

raco.out: info.rkt Makefile
	raco pkg catalog-show $$(cat "$<") > "$@"
