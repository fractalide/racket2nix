self: super:
let
  inherit (super.pkgs) lib;
in

lib.optionalAttrs (super ? "nix") {
  racket2nix = super.nix.overrideRacketDerivation (oldAttrs: { pname = "racket2nix"; });
} //
lib.optionalAttrs (super ? "deinprogramm-signature" && super ? "icons") {
  deinprogramm-signature = super.deinprogramm-signature.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "deinprogramm-signature+htdp-lib" && super ? "icons") {
  "deinprogramm-signature+htdp-lib" = super."deinprogramm-signature+htdp-lib".overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "gui-lib" && super ? "icons") {
  gui-lib = super.gui-lib.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
} //
lib.optionalAttrs (super ? "htdp-lib" && super ? "icons") {
  htdp-lib = super.htdp-lib.overrideRacketDerivation (oldAttrs: { racketBuildInputs = oldAttrs.racketBuildInputs ++ [ self.icons ]; });
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
lib.optionalAttrs (super ? "typed-racket-more") { typed-racket-more = super.typed-racket-more.overrideAttrs (_: {
  patches = [ (builtins.toFile "scheme-lib-dependency.patch" ''
--- a/typed-racket-more/info.rkt	2019-05-13 19:31:56.000000000 +0800
+++ b/typed-racket-more/info.rkt	2019-06-17 07:54:20.000000000 +0800
@@ -1 +1 @@
-(module info setup/infotab (#%module-begin (define package-content-state (quote (built "7.3"))) (define collection (quote multi)) (define deps (quote ("srfi-lite-lib" "base" "net-lib" "web-server-lib" ("db-lib" #:version "1.5") "draw-lib" "rackunit-lib" "rackunit-gui" "rackunit-typed" "snip-lib" "typed-racket-lib" "gui-lib" "pict-lib" "images-lib" "racket-index" "sandbox-lib"))) (define implies (quote ("rackunit-typed"))) (define pkg-desc "Types for various libraries") (define pkg-authors (quote (samth stamourv))) (define version "1.9")))
+(module info setup/infotab (#%module-begin (define package-content-state (quote (built "7.3"))) (define collection (quote multi)) (define deps (quote ("scheme-lib" "srfi-lite-lib" "base" "net-lib" "web-server-lib" ("db-lib" #:version "1.5") "draw-lib" "rackunit-lib" "rackunit-gui" "rackunit-typed" "snip-lib" "typed-racket-lib" "gui-lib" "pict-lib" "images-lib" "racket-index" "sandbox-lib"))) (define implies (quote ("rackunit-typed"))) (define pkg-desc "Types for various libraries") (define pkg-authors (quote (samth stamourv))) (define version "1.9")))
  '') ]; }); } //
lib.optionalAttrs (super ? "compatibility+compatibility-doc+data-doc+db-doc+distributed-p...") {
  "compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." = super."compatibility+compatibility-doc+data-doc+db-doc+distributed-p...".overrideAttrs (oldAttrs: {
  buildInputs = oldAttrs.buildInputs or [] ++ builtins.attrValues {
    inherit (self.pkgs) glib cairo fontconfig gmp gtk3 gsettings-desktop-schemas libedit libjpeg_turbo libpng mpfr openssl pango poppler readline sqlite;
  }; });
}
