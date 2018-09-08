{ pkgs ? import ../pkgs {}
}:

let
inherit (pkgs) buildRacket buildRacketCatalog racket racket2nix;

deps = {
a = [ "b" "c" "f" "g" "n" "o" "s" "y" ];
b = [ "d" ];
c = [ "d" ];
d = [ "a" "e" ];
e = [  ];
f = [  ];
g = [ "h" ];
h = [ "i" ];
i = [ "h" "j" ];
j = [ "a" ];
k = [ "l" ];
l = [ "m" "x" ];
m = [ "l" ];
n = [ "m" ];
o = [ "r" ];
p = [ "q" "r" ];
q = [ "a" ];
r = [ "p" ];
s = [ "t" ];
t = [ "u" "w" ];
u = [ "t" "v" ];
v = [  ];
w = [ "a" ];
x = [  ];
y = [ "z" ];
z = [ "a" ];
};

inherit (builtins) concatStringsSep;

nameDepsToDrv = name: deps: pkgs.runCommand name {
} ''
  mkdir $out
  cat > $out/info.rkt <<EOF
#lang info
(define version "0.0")
(define collection "${name}")
(define deps '("base" ${concatStringsSep " " (map (dep: "\"${dep}\"") deps)}))
(define build-deps '())
(define pkg-desc "Dummy package to validate that depending on circular dependencies works correctly.")
(define pkg-authors '("claes.wallin@greatsinodevelopment.com"))
(define racket-launcher-names '("${name}"))
(define racket-launcher-libraries '("main.rkt"))
EOF
  cat > $out/main.rkt <<EOF
#lang racket

${concatStringsSep "\n" (map (dep: "(require ${dep}/terminal)") deps)}

(provide (all-defined-out))

(define (${name}) (string-append
${concatStringsSep "\n" (map (dep: "  (${dep}-terminal)") deps)}))

(module+ main
  (displayln (${name})))
EOF

  cat > $out/terminal.rkt <<EOF
#lang racket/base

(provide (all-defined-out))

(define (${name}-terminal)
  "${name}")
EOF
'';

inherit (pkgs.lib) mapAttrs;

packages = mapAttrs nameDepsToDrv deps;

attrs = rec {
  catalog = buildRacketCatalog [ (builtins.attrValues packages) ];
  circular-subdeps = map (p: buildRacket { package = packages.${p}; inherit catalog; flat = false; })
                         [ "a" "k" ];
  circular-subdeps-flat = map (p: p.override { flat = true; }) circular-subdeps;
}; in

attrs // { inherit attrs; }
