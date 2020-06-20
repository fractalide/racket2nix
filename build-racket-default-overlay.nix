self: super:
let
  inherit (super.pkgs) lib;
in

lib.optionalAttrs (super ? "nix") {
  racket2nix = super.nix.overrideRacketDerivation (oldAttrs: { pname = "racket2nix"; });
} //
lib.optionalAttrs (super ? "racket-index") { racket-index = super.racket-index.overrideAttrs (_: {
  patches = [ (builtins.toFile "racket-index.patch" ''
    --- a/racket-index/setup/scribble.rkt
    +++ b/racket-index/setup/scribble.rkt
    @@ -874,6 +874,7 @@
             [(not latex-dest) (build-path (doc-dest-dir doc) file)]))
 
     (define (find-doc-db-path latex-dest user? main-doc-exists?)
    +  (set! main-doc-exists? #t)
       (cond
        [latex-dest
         (build-path latex-dest "docindex.sqlite")]
  '') ]; }); } //
lib.optionalAttrs (super ? "compatibility+compatibility-doc+data-doc+db-doc+distributed-p...") {
  "compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." = super."compatibility+compatibility-doc+data-doc+db-doc+distributed-p...".overrideAttrs (oldAttrs: {
  buildInputs = oldAttrs.buildInputs or [] ++ builtins.attrValues {
    inherit (self.pkgs) glib cairo fontconfig gmp gtk3 gsettings-desktop-schemas libedit libjpeg_turbo libpng mpfr openssl pango poppler readline sqlite;
  }; }); } //
lib.optionalAttrs (super ? "check-sexp-equal") { check-sexp-equal = super.check-sexp-equal.overrideAttrs (_: {
  patches = [ (builtins.toFile "check-sexp-equal.patch" ''
    diff -u check-sexp-equal.orig/info.rkt check-sexp-equal/info.rkt
    --- a/check-sexp-equal/info.rkt	2020-06-09 21:38:23.913644000 +0800
    +++ b/check-sexp-equal/info.rkt	2020-06-09 21:39:37.896841000 +0800
    @@ -6,6 +6,7 @@

     (define deps '(("sexp-diff" #:version "0.1")
                    "base"
    +               "racket-index"
                    "rackunit-lib"))

     (define build-deps '("racket-doc" "scribble-lib" "racket-doc"))
  '') ]; }); } //
lib.optionalAttrs (super ? "csv") { csv = super.csv.overrideAttrs (_: {
  patches = [ (builtins.toFile "csv.patch" ''
    diff -u a/csv/info.rkt b/csv/info.rkt
    --- a/csv/info.rkt	1970-01-01 08:00:01.000000000 +0800
    +++ b/csv/info.rkt	2020-06-09 22:19:39.260932000 +0800
    @@ -1,6 +1,7 @@
     #lang info
     (define collection "csv")
     (define deps '("base"
    +               "htdp-lib"
                    "rackunit-lib"))
     (define build-deps '("scribble-lib" "racket-doc"))
     (define scribblings '(("scribblings/csv.scrbl" ())))
  '') ]; }); }
