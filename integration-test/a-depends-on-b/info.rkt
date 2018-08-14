#lang info
(define version "0.0")
(define collection "a")
(define deps '("base" "b-depends-on-c"))
(define build-deps '())
(define pkg-desc "Dummy package to validate that depending on circular dependencies works correctly.")
(define pkg-authors '("claes.wallin@greatsinodevelopment.com"))
