#lang racket

(require net/url-string)
(require pkg/lib)
(require (prefix-in pkg-private: pkg/private/params))

(command-line
  #:args catalogs
  (begin
    (pkg-private:current-pkg-catalogs (map string->url catalogs))
    (write (get-all-pkg-details-from-catalogs))))
