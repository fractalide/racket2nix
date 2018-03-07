#! /usr/bin/env racket
#lang racket

(require pkg/lib)
(require racket/hash)

(define never-dependency-names '("racket"))
(define always-build-inputs '("racket"))
(define terminal-package-names '("racket-lib"))
(define force-reverse-circular-build-inputs #hash(
  ["htdp-lib" . ("deinprogramm-signature")]))

(define header-template #<<EOM
{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
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
  src = ./~a;
EOM
  )

(define derivation-template #<<EOM
stdenv.mkDerivation rec {
  name = "~a";
~a

  buildInputs = [ unzip ~a ];
  circularBuildInputs = [ ~a ];
  circularBuildInputsStr = stdenv.lib.concatStringsSep " " circularBuildInputs;
  reverseCircularBuildInputs = [ ~a ];
  srcs = [ src ] ++ (map (input: input.src) reverseCircularBuildInputs);

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
    runHook postUnpack
  '';

  patchPhase = ''
    case $name in
      racket-index)
        ( cd racket-index && patch -p3 < ${racketIndexPatch} )
        ;;
    esac
  '';

  dontBuild = true;

  racket-cmd = "${racket.out}/bin/racket -G $out/etc/racket -U -X $out/share/racket/collects";
  raco = "${racket-cmd} -N raco -l- raco";
  maxFileDescriptors = 2048;

  passAsFile = [ "racketConfig" ];

  racketConfig = ''
#hash(
  (share-dir . "$out/share/racket")
  (links-search-files . ( "$out/share/racket/links.rktd" ~a ))
  (pkgs-search-dirs . ( "$out/share/racket/pkgs" ~a ))
  (collects-search-dirs . ( "$out/share/racket/collects" ~a ))
  (doc-search-dirs . ( "$out/share/racket/doc" ~a ))
  (absolute-installation . #t)
  (installation-name . ".")
)
  '';

  installPhase = ''
    if ! ulimit -n $maxFileDescriptors; then
      echo >&2 If the number of allowed file descriptors is lower than '~~2048,'
      echo >&2 packages like drracket or racket-doc will not build correctly.
      echo >&2 If raising the soft limit fails '(like it just did)', you will
      echo >&2 have to raise the hard limit on your operating system.
      echo >&2 Examples:
      echo >&2 debian: https://unix.stackexchange.com/questions/127778
      echo >&2 MacOS: https://superuser.com/questions/117102
      exit 2
    fi

    mkdir -p $out/etc/racket $out/share/racket
    sed -e 's|$out|'"$out|g" > $out/etc/racket/config.rktd < $racketConfigPath

    remove_deps="${circularBuildInputsStr}"
    if [[ -n $remove_deps ]]; then
      sed -i $(printf -- '-e s/"%s"//g ' $remove_deps) $name/info.rkt
    fi

    echo ${racket-cmd}

    mkdir -p $out/share/racket/collects/
    for bootstrap_collection in racket compiler syntax setup openssl ffi file pkg planet; do
      cp -rs ${racket.out}/share/racket/collects/$bootstrap_collection \
        $out/share/racket/collects/
    done
    find $out/share/racket/collects -type d -exec chmod 755 {} +

    # install and link us
    if ${racket-cmd} -e "(require pkg/lib) (exit (if (member \"$name\" (installed-pkg-names #:scope (bytes->path (string->bytes/utf-8 \"${_racket-lib.out}/share/racket/pkgs\")))) 1 0))"; then
      install_names=$(for install_info in ./*/info.rkt; do echo ''${install_info%/info.rkt}; done)
      ${raco} pkg install --no-setup --copy --deps fail --fail-fast --scope installation $install_names
      if [ -z "${circularBuildInputsStr}" ]; then
        for install_name in $install_names; do
          case ''${install_name#./} in
            racket-doc|drracket) ;;
            *)
              ${raco} setup --no-user --no-pkg-deps --fail-fast --only --pkgs ''${install_name#./} |
                sed -ne '/updating info-domain/,$p'
              ;;
          esac
        done
      fi
    fi
    find $out/share/racket/collects -lname '${_racket-lib.out}/share/racket/collects/*' -delete
    find $out/share/racket/collects -type d -empty -delete
  '';
}
EOM
  )

(define (derivation name url sha1 dependency-names circular-dependency-names)
  (define build-inputs
    (string-join
      (append always-build-inputs
        (for/list ((name dependency-names))
          (format "_~a" name)))))
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
  (define link-files
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
                (format "\"${_~a.out}/share/racket/links.rktd\"" name))))
  (define pkgs-dirs
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
                (format "\"${_~a.out}/share/racket/pkgs\"" name))))
  (define collects-dirs
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
                (format "\"${_~a.out}/share/racket/collects\"" name))))
  (define doc-dirs
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
                (format "\"${_~a.out}/share/racket/doc\"" name))))
  (define src
    (if (string-prefix? url "http")
      (format fetchurl-template url sha1)
      (format localfile-template url)))

  (format derivation-template name src build-inputs circular-build-inputs
          reverse-circular-build-inputs-string
          link-files pkgs-dirs collects-dirs doc-dirs))

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
  (format "let~n~a~nin~n" derivations-on-lines))

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

(define package-name
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
(display (string-append (header) (name->let-deps-and-reference package-name pkg-details)))
