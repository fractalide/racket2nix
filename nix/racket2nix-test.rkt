#lang racket
(require nix/racket2nix)
(require rackunit)

(provide (all-defined-out))

(define suite (begin
  (test-suite "racket2nix"
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
                 "git://github.com/stchang/parsack.git"))))
