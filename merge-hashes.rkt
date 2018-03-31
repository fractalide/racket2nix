#lang racket
(require racket/hash)
(command-line
  #:program "merge-hashes" #:args catalogs
  (write (for/hash
    ([kv (append* (for/list
      ([catalog catalogs])
      (hash->list (call-with-input-file* catalog read))))])
    (match-define (cons k v) kv)
    (values k v))))
