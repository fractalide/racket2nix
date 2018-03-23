#lang info
(define version "0.0")
(define collection "nix")
(define deps '("base" "rackunit-lib"))
(define build-deps '())
(define pkg-desc "Creates Nix derivations for Racket packages and their dependencies.")
(define pkg-authors '("claes.wallin@greatsinodevelopment.com"))
(define racket-launcher-names '("racket2nix"))
(define racket-launcher-libraries '("racket2nix.rkt"))
