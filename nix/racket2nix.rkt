#! /usr/bin/env racket
#lang racket

(require pkg/lib)
(require racket/hash)
(require setup/getinfo)

(define never-dependency-names '("racket"))
(define terminal-package-names '("racket-lib"))
(define force-reverse-circular-build-inputs #hash(
  ["drracket-tool-lib" . ("racket-index")]
  ["plai-lib" . ("racket-index" "drracket-tool-lib")]
  ["rackunit-typed" . ("racket-index")]
  ["typed-racket-more" . ("racket-index" "rackunit-typed")]
  ["htdp-lib" . ("deinprogramm-signature" "racket-index" "plai-lib" "drracket-tool-lib"
                 "rackunit-typed" "typed-racket-more")]

  ["math-lib" . ("racket-index" "rackunit-typed" "typed-racket-more")]
  ["data-enumerate-lib" . ("racket-index" "rackunit-typed" "typed-racket-more" "math-lib")]
  ["plot-lib" . ("racket-index" "rackunit-typed" "typed-racket-more" "math-lib")]
  ["plot-gui-lib" . ("racket-index" "rackunit-typed" "typed-racket-more" "math-lib" "plot-lib")]
  ["plot-compat" . ("racket-index" "rackunit-typed" "typed-racket-more" "math-lib" "plot-lib"
                    "plot-gui-lib")]))

(define header-template #<<EOM
{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
, lib ? stdenv.lib
, fetchurl ? pkgs.fetchurl
, racket ? pkgs.racket-minimal
, racket-lib ? racket
, unzip ? pkgs.unzip
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

let mkRacketDerivation = lib.makeOverridable (attrs: stdenv.mkDerivation (rec {
  buildInputs = [ unzip racket attrs.racketBuildInputs ];
  circularBuildInputsStr = lib.concatStringsSep " " attrs.circularBuildInputs;
  racketBuildInputsStr = lib.concatStringsSep " " attrs.racketBuildInputs;
  racketConfigBuildInputs = builtins.filter (input: ! builtins.elem input attrs.reverseCircularBuildInputs) attrs.racketBuildInputs;
  racketConfigBuildInputsStr = lib.concatStringsSep " " racketConfigBuildInputs;
  srcs = [ attrs.src ] ++ (map (input: input.src) attrs.reverseCircularBuildInputs);
  inherit racket;

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

  racket-cmd = "${racket.out}/bin/racket -G $out/etc/racket -U -X $out/share/racket/collects";
  raco = "${racket-cmd} -N raco -l- raco";
  maxFileDescriptors = 2048;

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

    if ! ulimit -n $maxFileDescriptors; then
      echo >&2 If the number of allowed file descriptors is lower than '~2048,'
      echo >&2 packages like drracket or racket-doc will not build correctly.
      echo >&2 If raising the soft limit fails '(like it just did)', you will
      echo >&2 have to raise the hard limit on your operating system.
      echo >&2 Examples:
      echo >&2 debian: https://unix.stackexchange.com/questions/127778
      echo >&2 MacOS: https://superuser.com/questions/117102
      exit 2
    fi

    mkdir -p $out/etc/racket $out/share/racket
    # Don't use racket-cmd as config.rktd doesn't exist yet.
    racket ${make-config-rktd} $out ${racket} ${racketConfigBuildInputsStr} > $out/etc/racket/config.rktd

    remove_deps="${circularBuildInputsStr}"
    if [[ -n $remove_deps ]]; then
      sed -i $(printf -- '-e s/"%s"//g ' $remove_deps) $name/info.rkt
    fi

    echo ${racket-cmd}

    mkdir -p $out/share/racket/collects $out/lib $out/bin
    for bootstrap_collection in racket compiler syntax setup openssl ffi file pkg planet; do
      cp -rs ${racket.out}/share/racket/collects/$bootstrap_collection \
        $out/share/racket/collects/
    done
    cp -rs $racket/lib/racket $out/lib/racket
    find $out/share/racket/collects $out/lib/racket -type d -exec chmod 755 {} +

    printf > $out/bin/racket "#! /usr/bin/env bash\nexec ${racket-cmd} \"\$@\"\n"
    chmod 555 $out/bin/racket

    # install and link us
    if ${racket-cmd} -e "(require pkg/lib) (exit (if (member \"$name\" (installed-pkg-names #:scope (bytes->path (string->bytes/utf-8 \"${_racket-lib.out}/share/racket/pkgs\")))) 1 0))"; then
      install_names=$(for install_info in ./*/info.rkt; do echo ''${install_info%/info.rkt}; done)
      ${raco} pkg install --no-setup --copy --deps fail --fail-fast --scope installation $install_names
      if [ -z "${circularBuildInputsStr}" ]; then
        for install_name in $install_names; do
          case ''${install_name#./} in
            drracket|racket-doc|racket-index) ;;
            *)
              ${raco} setup --no-user --no-pkg-deps --fail-fast --only --pkgs ''${install_name#./} # |
                # sed -ne '/updating info-domain/,$p'
              ;;
          esac
        done
      fi
    fi

    runHook postInstall

    find $out/share/racket/collects $out/lib/racket -lname '${_racket-lib.out}/*' -delete
    find $out/share/racket/collects $out/lib/racket $out/bin -type d -empty -delete
  '';
} // attrs));


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

(define (derivation name url sha1 dependency-names circular-dependency-names)
  (define build-inputs
    (string-join
      (for/list ((name dependency-names))
        (format "_~a" name))))
  (define circular-build-inputs
    (string-join
      (for/list ((name circular-dependency-names))
        (format "\"~a\"" name))))
  (define reverse-circular-build-inputs
    (hash-ref force-reverse-circular-build-inputs name
              (lambda () '())))
  (define reverse-circular-build-inputs-string
    (string-join (map (lambda (s) (format "_~a" s)) reverse-circular-build-inputs)))
  (define non-reverse-circular-dependency-names
    (remove* reverse-circular-build-inputs dependency-names))
  (define src
    (if (string-prefix? url "http")
      (format fetchurl-template url sha1)
      (format localfile-template url)))

  (format derivation-template name src build-inputs circular-build-inputs
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

(define (names->let-deps names package-dictionary)
  (define terminal-derivations
    (for/list ((name terminal-package-names))
      (format "  _~a = ~a;" name name)))
  (define derivations
    (for/list ((name (remove* terminal-package-names names)))
      (format "  _~a = ~a;" name (name->derivation name package-dictionary))))
  (define derivations-on-lines
    (string-join (append terminal-derivations derivations) (format "~n")))
  (format "~a~nin~n" derivations-on-lines))

(define (name->transitive-dependency-names package-name package-dictionary (breadcrumbs '()))
  (when (member package-name breadcrumbs)
    (raise-argument-error 'name->transitive-dependency-names
                          "not supposed to be a circular dependency"
                          0 package-name breadcrumbs))

  (define package (memo-lookup-package package-dictionary package-name))

  (hash-ref!
   package
   'transitive-dependency-names
   (lambda ()
     (cond
       [(member package-name terminal-package-names) (list package-name)]
       [else
        (define new-crumbs (cons package-name breadcrumbs))
        (define dependency-names
          (package->transitive-dependency-names package package-dictionary new-crumbs))
        dependency-names]))))

(define (package->transitive-dependency-names package package-dictionary breadcrumbs)
  (define name (hash-ref package 'name))
  (define raw-dependency-names (hash-ref package 'dependency-names))

  (define noncircular-parents (remove* raw-dependency-names breadcrumbs))
  (define circular-parents (remove* noncircular-parents breadcrumbs))

  (define dependency-names (remove* circular-parents raw-dependency-names))

  (hash-set! package 'circular-dependencies circular-parents)
  (hash-set! package 'dependency-names dependency-names)

  (define name-lists
    (for/list ((name dependency-names))
      (name->transitive-dependency-names name package-dictionary breadcrumbs)))
  (append (remove-duplicates (append* name-lists)) (list name)))

(define (name->derivation package-name package-dictionary)
  (define package (memo-lookup-package package-dictionary package-name))
  (package->derivation package package-dictionary))

(define (package->derivation package package-dictionary)
  (define name (hash-ref package 'name))
  (define url (hash-ref package 'source))
  (define sha1 (hash-ref package 'checksum))
  (define dependency-names (hash-ref package 'dependency-names))
  (define circular-dependency-names (hash-ref package 'circular-dependencies))
  (define trans-dep-names
    (remove-duplicates
     (append*
      (for/list ((name dependency-names))
        (name->transitive-dependency-names name package-dictionary)))))
  (derivation name url sha1 trans-dep-names circular-dependency-names))

(define (name->let-deps-and-reference package-name package-dictionary)
  (define package-names (name->transitive-dependency-names package-name package-dictionary))
  (define package-definitions (names->let-deps package-names package-dictionary))
  (string-append package-definitions (format "_~a~n" package-name)))

(define catalog-paths #f)

(define package-name-or-path
  (command-line
    #:program "racket2nix"
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

(display (string-append (header) (name->let-deps-and-reference package-name pkg-details)))
