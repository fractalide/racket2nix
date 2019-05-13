#lang racket

(require net/url-string)
(require pkg/lib)
(require (prefix-in pkg-private: pkg/private/params))
(require (only-in "racket2nix.rkt" pretty-write-sorted-string-hash))

(command-line
  #:args catalogs
  (pkg-private:current-pkg-catalogs (map string->url catalogs))
  (pretty-write-sorted-string-hash (get-all-pkg-details-from-catalogs)))
