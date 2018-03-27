#! /usr/bin/env racket
#lang racket

(require pkg/lib)
(require racket/hash)
(require setup/getinfo)

(provide (all-defined-out))

(define never-dependency-names '("racket"))
(define terminal-package-names '("racket-lib"))
(define force-reverse-circular-build-inputs #hash(
  ["racket-index" . ("scribble-lib")]
  ["racket-doc" . ("scribble-lib")]
))

(define header-template #<<EOM
{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
, lib ? stdenv.lib
, fetchurl ? pkgs.fetchurl
, racket ? pkgs.racket-minimal
, racket-lib ? racket // { env = racket.out; }
, unzip ? pkgs.unzip
, bash ? pkgs.bash
, racketIndexPatch ? builtins.toFile "racket-index.patch" ''
    diff --git a/pkgs/racket-index/setup/scribble.rkt b/pkgs/racket-index/setup/scribble.rkt
    index c79af9bf85..e4a1cf93e3 100644
    --- a/pkgs/racket-index/setup/scribble.rkt
    +++ b/pkgs/racket-index/setup/scribble.rkt
    @@ -874,6 +874,7 @@
             [(not latex-dest) (build-path (doc-dest-dir doc) file)]))
 
     (define (find-doc-db-path latex-dest user? main-doc-exists?)
    +  (set! main-doc-exists? #t)
       (cond
        [latex-dest
         (build-path latex-dest "docindex.sqlite")]
  ''
}:

let mkRacketDerivation = suppliedAttrs: let racketDerivation = lib.makeOverridable (attrs: stdenv.mkDerivation (rec {
  buildInputs = [ unzip racket attrs.racketBuildInputs ];
  circularBuildInputsStr = lib.concatStringsSep " " attrs.circularBuildInputs;
  racketBuildInputsStr = lib.concatStringsSep " " attrs.racketBuildInputs;
  racketConfigBuildInputs = builtins.filter (input: ! builtins.elem input attrs.reverseCircularBuildInputs) attrs.racketBuildInputs;
  racketConfigBuildInputsStr = lib.concatStringsSep " " (map (drv: drv.env) racketConfigBuildInputs);
  srcs = [ attrs.src ]
           ++ attrs.extraSrcs or (map (input: input.src) attrs.reverseCircularBuildInputs);
  inherit racket;
  outputs = [ "out" "env" ];

  phases = "unpackPhase patchPhase installPhase fixupPhase";
  unpackPhase = ''
    stripSuffix() {
      stripped=$1
      for suffix in .gz .tgz .zip .xz .tar; do
        stripped=''${stripped%$suffix}
      done
      echo $stripped
    }

    runHook preUnpack
    for unpackSrc in $srcs; do
      unpackName=$(stripSuffix $(stripHash $unpackSrc))
      mkdir $unpackName
      cd $unpackName
      unpackFile $unpackSrc
      cd -
      unpackedFiles=( $unpackName/* )
      if [ "''${unpackedFiles[*]}" = "$unpackName/$unpackName" ]; then
        mv $unpackName _
        chmod u+w _/$unpackName
        mv _/$unpackName $unpackName
        rmdir _
      fi
    done
    chmod u+w -R .
    find . -name '*.zo' -delete
    runHook postUnpack
  '';

  patchPhase = ''
    if [ -d racket-index ]; then
        ( cd racket-index && patch -p3 < ${racketIndexPatch} )
    fi
  '';

  racket-cmd = "${racket}/bin/racket -G $env/etc/racket -U -X $env/share/racket/collects";
  raco = "${racket-cmd} -N raco -l- raco";
  maxFileDescriptors = 3072;

  make-config-rktd = builtins.toFile "make-config-rktd.rkt" ''
    #lang racket

    (define (make-config-rktd out racket deps)
      (define out-deps-racket (append (list racket) (cons out deps)))
      (define (share/racket suffix)
        (for/list ((path out-deps-racket))
                  (format "~a/share/racket/~a" path suffix)))

      (define lib-dirs
        (append
          (for/list ((name (cons out deps)))
                    (format "~a/share/racket/lib" name))
          (list (format "~a/lib/racket" racket))))

      (define config-rktd
        `#hash(
          (share-dir . ,(format "~a/share/racket" out))
          (lib-search-dirs . ,lib-dirs)
          (lib-dir . ,(format "~a/lib/racket" out))
          (bin-dir . ,(format "~a/bin" out))
          (absolute-installation . #t)
          (installation-name . ".")

          (links-search-files . ,(share/racket "links.rktd"))
          (pkgs-search-dirs . ,(share/racket "pkgs"))
          (collects-search-dirs . ,(share/racket "collects"))
          (doc-search-dirs . ,(share/racket "doc"))
        ))
      (write config-rktd))

    (command-line
      #:program "make-config-rktd"
      #:args (out racket . deps)
             (make-config-rktd out racket deps))
  '';

  installPhase = ''
    runHook preInstall

    restore_pipefail=$(shopt -po pipefail)
    set -o pipefail

    if ! ulimit -n $maxFileDescriptors; then
      echo >&2 If the number of allowed file descriptors is lower than '~3072,'
      echo >&2 packages like drracket or racket-doc will not build correctly.
      echo >&2 If raising the soft limit fails '(like it just did)', you will
      echo >&2 have to raise the hard limit on your operating system.
      echo >&2 Examples:
      echo >&2 debian: https://unix.stackexchange.com/questions/127778
      echo >&2 MacOS: https://superuser.com/questions/117102
      exit 2
    fi

    mkdir -p $env/etc/racket $env/share/racket $out
    # Don't use racket-cmd as config.rktd doesn't exist yet.
    racket ${make-config-rktd} $env ${racket} ${racketConfigBuildInputsStr} > $env/etc/racket/config.rktd

    if [ -n "${circularBuildInputsStr}" ]; then
      echo >&2 WARNING: This derivation should not have been depended on.
      echo >&2 Any derivation depending on this one should have depended on one of these instead:
      echo >&2 "${circularBuildInputsStr}"
      exit 0
    fi

    echo ${racket-cmd}

    mkdir -p $env/share/racket/collects $env/lib $env/bin
    for bootstrap_collection in racket compiler syntax setup openssl ffi file pkg planet; do
      cp -rs $racket/share/racket/collects/$bootstrap_collection \
        $env/share/racket/collects/
    done
    cp -rs $racket/lib/racket $env/lib/racket
    find $env/share/racket/collects $env/lib/racket -type d -exec chmod 755 {} +

    printf > $env/bin/racket "#!${bash}/bin/bash\nexec ${racket-cmd} \"\$@\"\n"
    chmod 555 $env/bin/racket

    # install and link us
    install_names=""
    for install_info in ./*/info.rkt; do
      install_name=''${install_info%/info.rkt}
      if ${racket-cmd} -e "(require pkg/lib)
                           (define name \"''${install_name#./}\")
                           (for ((scope (get-all-pkg-scopes)))
                             (when (member name (installed-pkg-names #:scope scope))
                                   (eprintf \"WARNING: ~a already installed in ~a -- not installing~n\"
                                            name scope)
                                   (exit 1)))"; then
        install_names+=" $install_name"
      fi
    done

    if [ -n "$install_names" ]; then
      ${raco} pkg install --no-setup --copy --deps fail --fail-fast --scope installation $install_names |&
        sed -Ee '/warning: tool "(setup|pkg|link)" registered twice/d'

      setup_names=""
      for setup_name in $install_names; do
        setup_names+=" ''${setup_name#./}"
      done
      ${raco} setup --no-user --no-pkg-deps --fail-fast --only --pkgs $setup_names |&
        sed -ne '/updating info-domain/,$p'
    fi

    mkdir -p $out/bin
    for launcher in $env/bin/*; do
      if ! [ "''${launcher##*/}" = racket ]; then
        ln -s "$launcher" "$out/bin/''${launcher##*/}"
      fi
    done

    eval "$restore_pipefail"
    runHook postInstall

    find $env/share/racket/collects $env/lib/racket -lname "$racket/*" -delete
    find $env/share/racket/collects $env/lib/racket $env/bin -type d -empty -delete
  '';
} // attrs)) suppliedAttrs; in racketDerivation // { inherit racketDerivation; };


EOM
  )

(define fetchurl-template #<<EOM
  src = fetchurl {
    url = "~a";
    sha1 = "~a";
  };
EOM
  )

(define localfile-template #<<EOM
  src = ~a;
EOM
  )

(define derivation-template #<<EOM
mkRacketDerivation rec {
  name = "~a";
~a
  racketBuildInputs = [ ~a ];
  circularBuildInputs = [ ~a ];
  reverseCircularBuildInputs = [ ~a ];
  }
EOM
  )

(define (derivation name url sha1 dependency-names circular-dependency-names
                    (override-reverse-circular-build-inputs #f))

  (define reverse-circular-build-inputs
    (if override-reverse-circular-build-inputs
        override-reverse-circular-build-inputs
        (hash-ref force-reverse-circular-build-inputs name list)))
  (define non-reverse-circular-dependency-names
    (remove* reverse-circular-build-inputs dependency-names))

  (define racket-build-inputs
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
        (format "_~a" name))))
  (define circular-build-inputs
    (string-join
      (for/list ((name circular-dependency-names))
        (format "\"~a\"" name))))
  (define reverse-circular-build-inputs-string
    (string-join
      (for/list ((input reverse-circular-build-inputs))
        (format "\"~a\"" input))))
  (define src
    (if (string-prefix? url "http")
      (format fetchurl-template url sha1)
      (format localfile-template url)))
  (define srcs
    (cond
      [(pair? reverse-circular-build-inputs)
       (define srcs-refs (string-join (map (lambda (s) (format "_~a.src" s)) reverse-circular-build-inputs)))
       (format "~n  extraSrcs = [ ~a ];" srcs-refs)]
      [else ""]))

  (format derivation-template name (string-join (list src srcs) "")
          racket-build-inputs circular-build-inputs
          reverse-circular-build-inputs-string))

(define (header) header-template)

(define (memo-lookup-package package-dictionary package-name)
  (define package (hash-ref package-dictionary package-name))
  (cond [(hash-ref package 'dependency-names (lambda () #f)) package]
        [else
          (define new-package (hash-copy package))
          (hash-set! new-package 'dependency-names
            (remove* never-dependency-names
              (map dependency-name (hash-ref package 'dependencies (lambda () '())))))
          (hash-set! package-dictionary package-name new-package)
          new-package]))

(define (dependency-name pair-or-string)
  (if (pair? pair-or-string)
      (car pair-or-string)
      pair-or-string))

(define (names->let-deps #:flat? (flat? #f) names package-dictionary)
  (define terminal-derivations
    (for/list ((name terminal-package-names))
      (format "  _~a = ~a;" name name)))
  (define derivations
    (for/list ((name (remove* terminal-package-names names)))
      (format "  _~a = ~a;" name (name->derivation #:flat? flat? name package-dictionary))))
  (define derivations-on-lines
    (string-join (append terminal-derivations derivations) (format "~n")))
  (format "~a~nin~n" derivations-on-lines))

(define (name->transitive-dependency-names package-name package-dictionary (breadcrumbs '()))
  (when (member package-name breadcrumbs)
    (raise-argument-error 'name->transitive-dependency-names
                          "not supposed to be a circular dependency"
                          0 package-name breadcrumbs))

  (define package (memo-lookup-package package-dictionary package-name))
  (define transitive-dependency-names (hash-ref package 'transitive-dependency-names #f))

  (cond [transitive-dependency-names (values transitive-dependency-names
                                             transitive-dependency-names
                                             (hash-ref package 'cycles))]
        [(member package-name terminal-package-names) (values (list package-name)
                                                              (list package-name)
                                                              #hash())]
        [else
          (define new-crumbs (append breadcrumbs (list package-name)))
          (package->transitive-dependency-names package package-dictionary new-crumbs)]))

(define (package->transitive-dependency-names package package-dictionary breadcrumbs)
  (define name (hash-ref package 'name))
  (define raw-dependency-names (hash-ref package 'dependency-names))

  ; We cannot trust set-subtract to retain order
  (define noncircular-parents (remove* raw-dependency-names breadcrumbs))
  (define circular-parents (remove* noncircular-parents breadcrumbs))

  (define dependency-names (remove* circular-parents raw-dependency-names))

  (define-values (transitive-dependency-names
                  trimmed-transitive-dependency-names
                  cycles)
    (for/fold ([transitive-dependency-names dependency-names]
               [trimmed-transitive-dependency-names dependency-names]
               [cycles (for/hash ([parent circular-parents]) (values parent (list name)))])
              ([name dependency-names])
      (define-values (sub-transnames sub-trimnames sub-cycles)
        (name->transitive-dependency-names name package-dictionary breadcrumbs))
      (values (remove-duplicates (append transitive-dependency-names sub-transnames))
              (remove-duplicates (append trimmed-transitive-dependency-names sub-trimnames))
              (for/hash ([key (remove-duplicates (append (hash-keys cycles)
                                                         (hash-keys sub-cycles)))])
                (values key
                        (remove-duplicates (append (hash-ref cycles key list)
                                                   (hash-ref sub-cycles key list))))))))

  (for ([key (hash-keys cycles)])
    (cond [(equal? key name)]  ; If we're a cycle top, resolve that after other cycles.
          [(member key breadcrumbs)
           (set! cycles (hash-set cycles key
                                  (remove-duplicates (append (hash-ref cycles key)
                                                             (list name)))))
           (set! circular-parents (remove-duplicates (append circular-parents (list key))))
           (set! trimmed-transitive-dependency-names
                 (remove* (hash-ref cycles key) trimmed-transitive-dependency-names))]
          [else  ; We came to this cycle from the side
           (let* ([cycle-top (hash-ref package-dictionary key)]
                  [cycle-transdeps (hash-ref cycle-top 'transitive-dependency-names)]
                  [cycle-revcircs (hash-ref cycle-top 'reverse-circular-build-inputs)])
             (set! dependency-names (remove-duplicates
                                     (append (remove* cycle-revcircs dependency-names)
                                             (list key))))
             (set! trimmed-transitive-dependency-names
                   (remove-duplicates
                    (append (remove* cycle-revcircs trimmed-transitive-dependency-names)
                            cycle-transdeps)))
             (set! cycles (hash-remove cycles key)))]))

  (define my-cycle (hash-ref cycles name #f))
  (when my-cycle
        (hash-set! package 'reverse-circular-build-inputs my-cycle)
        ; If our circle is within another circle, merge them.
        (for ((other-cycle (remove name (hash-keys cycles))))
          (set! cycles (hash-set cycles other-cycle
                                 (remove-duplicates (append (hash-ref cycles other-cycle)
                                                            my-cycle)))))
        (set! cycles (hash-remove cycles name)))

  (define full-circle-parents
    (remove name
            (remove-duplicates (append* (for/list ((parent circular-parents))
                                          (member parent breadcrumbs))))))

  (hash-set! package 'circular-dependencies full-circle-parents)
  (hash-set! package 'dependency-names dependency-names)
  (hash-set! package 'transitive-dependency-names trimmed-transitive-dependency-names)
  (hash-set! package 'cycles cycles)

  (values (append transitive-dependency-names (list name))
          (append trimmed-transitive-dependency-names (list name))
          cycles))

(define (name->derivation #:flat? (flat? #f) package-name package-dictionary)
  (define package (memo-lookup-package package-dictionary package-name))
  (package->derivation #:flat? flat? package package-dictionary))

(define (package->derivation #:flat? (flat? #f) package package-dictionary)
  (define name (hash-ref package 'name))
  (define url (hash-ref package 'source))
  (define sha1 (hash-ref package 'checksum))
  (define dependency-names (hash-ref package 'dependency-names))
  (define circular-dependency-names (hash-ref package 'circular-dependencies))
  (define trans-dep-names (hash-ref package 'transitive-dependency-names))
  (define reverse-circular-dependency-names
    (cond
      [flat? (remove* terminal-package-names trans-dep-names)]
      [else
        (define calculated-reverse-circular
                (hash-ref package 'reverse-circular-build-inputs
                          (lambda () '())))
        (define forced-reverse-circular
                (hash-ref force-reverse-circular-build-inputs name
                          (lambda () '())))
        (remove-duplicates (append calculated-reverse-circular forced-reverse-circular))]))
    (derivation name url sha1 trans-dep-names circular-dependency-names
                reverse-circular-dependency-names))

(define (name->let-deps-and-reference #:flat? (flat? #f) package-name package-dictionary)
  (define-values (package-names _ __)
    (name->transitive-dependency-names package-name package-dictionary))
  (define package-definitions (names->let-deps #:flat? flat? package-names package-dictionary))
  (string-append package-definitions (format "_~a~n" package-name)))

(define (name->nix-function #:flat? (flat? #f) package-name package-dictionary)
  (string-append (header) (name->let-deps-and-reference #:flat? flat? package-name package-dictionary)))

(module+ main
  (define catalog-paths #f)
  (define flat? #f)

  (define package-name-or-path
    (command-line
      #:program "racket2nix"
      #:once-each
      [("--test") "Ignore everything else and just run the tests."
                   (if (> ((dynamic-require 'rackunit/text-ui 'run-tests)
                           (dynamic-require 'nix/racket2nix-test 'suite))
                          0)
                       (exit 1)
                       (exit 0))]
      [("--flat")  "Do not try to install each dependency separately, just install and setup all dependencies in the main derivation."
                   (set! flat? #t)]
      #:multi
      ["--catalog" catalog-path
                   "Read from this catalog instead of downloading catalogs. Can be provided multiple times to use several catalogs. Later given catalogs have lower precedence."
                   (set! catalog-paths (cons catalog-path (or catalog-paths '())))]
      #:args (package-name) package-name))

  (define pkg-details (make-hash))

  (cond
    [catalog-paths
      (for [(catalog-path catalog-paths)]
         (hash-union! pkg-details (call-with-input-file* catalog-path read)))]
    [else
      (eprintf "Fetching package catalogs...~n")
      (hash-union! pkg-details (get-all-pkg-details-from-catalogs))])

  (define package-name (cond
    [(string-contains? package-name-or-path "/")
     (define name (string-replace package-name-or-path #rx".*/" ""))
     (define path package-name-or-path)
     (hash-set!
       pkg-details name
       `#hash(
          (name . ,name)
          (source . ,path)
          (dependencies . ,(extract-pkg-dependencies (get-info/full path) #:build-deps? #t))
          (checksum . "")
        ))
     name]
    [else package-name-or-path]))

  (display (name->nix-function #:flat? flat? package-name pkg-details)))
