#lang racket/base

(require c)

(provide (all-defined-out))

(define (b-dummy x) (c-dummy x))
