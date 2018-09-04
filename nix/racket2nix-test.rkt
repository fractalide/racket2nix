#lang racket
(require nix/racket2nix)
(require rackunit)

(provide (all-defined-out))

(define pkgs-params '(("a" ("b" "c" "f" "g" "n" "o" "s" "y"))
                      ("b" ("d"))
                      ("c" ("d"))
                      ("d" ("a" "e"))
                      ("e" ())
                      ("f" ())
                      ("g" ("h"))
                      ("h" ("i"))
                      ("i" ("h" "j"))
                      ("j" ("a"))
                      ("k" ("l"))
                      ("l" ("m" "x"))
                      ("m" ("l"))
                      ("n" ("m"))
                      ("o" ("r"))
                      ("p" ("q" "r"))
                      ("q" ("a"))
                      ("r" ("p"))
                      ("s" ("t"))
                      ("t" ("u" "w"))
                      ("u" ("t" "v"))
                      ("v" ())
                      ("w" ("a"))
                      ("x" ())
                      ("y" ("z"))
                      ("z" ("a"))))

(define pkgs-names (map car pkgs-params))

(define (scaffold)
  (define (new-pkg name path deps)
     `#hash(
        (name . ,name)
        (source . ,path)
        (dependencies . ,deps)
        (checksum . "")))
  (define (new-pkg-values name path deps)
    (values name (new-pkg name path deps)))
  (hash-copy
    (for/hash ([pkg-params pkgs-params])
       (match-define (list name deps) pkg-params)
       (new-pkg-values name (string-join (list "./" name) "") deps))))

(define (deps #:flat? (flat? #f) (observed-top-name "a"))
  (define s (scaffold))
  (names->nix-function #:flat? flat? '("a") s)
  (define observed-top (hash-ref s observed-top-name))
  (define transitive (hash-ref observed-top 'transitive-dependency-names))
  (define reverse-circular (hash-ref observed-top 'reverse-circular-build-inputs list))
  (values transitive reverse-circular))

(define (test-transitive-dependencies title #:observed-top (observed-top-name "a") . pkg-names)
  (test-case title
    (define-values (transitive reverse-circular) (deps observed-top-name))
    (for ([pkg-name pkg-names])
      (check-false (member pkg-name reverse-circular)
                   (format "~a is not in the cycle ~a" pkg-name reverse-circular))
      (check-not-false (member pkg-name transitive)
                       (format "~a is in the transitive dependencies ~a" pkg-name transitive)))))

(define (test-reverse-circular-dependencies title
                                            #:flat? (flat? #f)
                                            #:observed-top (observed-top-name "a")
                                            . pkg-names)
  (test-case title
    (define-values (transitive reverse-circular) (deps #:flat? flat? observed-top-name))
    (for ([pkg-name pkg-names])
      ; (check-false (member pkg-name transitive)
      ;              (format "~a is not in the transitive dependencies ~a" pkg-name transitive))
      (check-not-false (member pkg-name reverse-circular)
                       (format "~a is in the cycle ~a" pkg-name reverse-circular)))))

(define suite
  (test-suite "racket2nix"
    ;; This test cannot work yet, as the flattening mechanism is currently done outside the transitive
    ;; dependencies resolution mechanism.
    ; (apply test-reverse-circular-dependencies "Flat" #:flat? #t (remove* '("a" "k") pkgs-names))
    (test-reverse-circular-dependencies "Diamond cycle" "b" "c" "d")
    (test-reverse-circular-dependencies "Left inner cycle in main cycle" "g" "h" "i" "j")
    (test-reverse-circular-dependencies "Right inner cycle in main cycle" "o" "p" "q" "r")
    (test-reverse-circular-dependencies "Subcycle merged into main cycle" "s" "t" "u" "w")
    (test-reverse-circular-dependencies "Plain cycle" "y" "z")
    (test-reverse-circular-dependencies "Local cycle" #:observed-top "m" "l")
    (test-transitive-dependencies "Local cycle not in main cycle" "m")
    ; (test-not-transitive-dependencies "Local cycle bottom not in main transdeps" "l")
    (test-transitive-dependencies "Plain dependency" "f")
    (test-transitive-dependencies "Plain dependency below diamond" "e")
    (test-transitive-dependencies "Plain dependency below local cycle" "x")
    (test-transitive-dependencies "Plain dependency below subcycle" "v")
    (test-equal? "github-url->git-url turns github://.*/branch into git://.*#branch"
                 (github-url->git-url "github://github.com/mordae/racket-systemd/master")
                 "git://github.com/mordae/racket-systemd.git#master")
    (test-not-false "github-url? detects github:// URL"
                 (github-url? "github://github.com/mordae/racket-systemd/master"))
    (test-equal? "url-fallback-rev->url-rev-path tolerates github:// with trailing slash"
                 (match-let-values
                   ([(url _ _)
                     (url-fallback-rev->url-rev-path
                       "github://github.com/stchang/parsack/master/"
                       "b45f0f5ed5f8dd3f1ccebaaec3204b27032843c6")])
                   url)
                 "git://github.com/stchang/parsack.git")))
