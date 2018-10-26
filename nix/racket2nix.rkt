#! /usr/bin/env racket
#lang racket

(require json)
(require pkg/lib)
(require racket/hash)
(require racket/runtime-path)
(require setup/getinfo)

(provide (all-defined-out))

(define never-dependency-names '("racket"))
(define terminal-package-names '("racket-lib"))
(define force-reverse-circular-build-inputs #hash(
  ["make" . ("scribble-lib")]
  ["memoize" . ("scribble-lib")]
  ["racket-index" . ("scribble-lib")]
  ["compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." . ("scribble-lib" "racket-index")]
))

(define header-template #<<EOM
{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
, lib ? stdenv.lib
, fetchurl ? pkgs.fetchurl
, fetchgit ? pkgs.fetchgit
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

let racket-packages = lib.makeExtensible (self: {
inherit pkgs;

lib.extractPath = lib.makeOverridable ({ path, src }: stdenv.mkDerivation {
  inherit path src;
  name = let
    pathComponents = lib.splitString "/" path;
    numComponents = builtins.length pathComponents;
  in builtins.elemAt pathComponents (numComponents - 1);
  phases = "unpackPhase installPhase";
  installPhase = ''
    cp -a "${path}" $out
  '';
});

lib.stripHash = path:
  let
    storeStripped = lib.removePrefix "/" (lib.removePrefix builtins.storeDir path);
    finalLength = (builtins.stringLength storeStripped) - 33;
  in
    builtins.substring 33 finalLength storeStripped;

lib.fixedRacketSource = { pathname, sha256 }: pkgs.runCommand (baseNameOf (self.lib.stripHash pathname)) {
  inherit pathname;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = sha256;
  buildInputs = [ pkgs.coreutils ];
} ''
  cp -a $pathname $out && exit
  echo ERROR: Unable to find source for $name: $pathname
'';

lib.resolveThinInputs = let resolve = thinInputs: if thinInputs == [] then [] else
  let head = builtins.head thinInputs; tail = builtins.tail thinInputs; in
  [ head ] ++ head.racketBuildInputs or [] ++ resolve head.racketThinBuildInputs or [] ++ resolve tail;
  in resolve;
lib.mkRacketDerivation = suppliedAttrs: let racketDerivation = lib.makeOverridable (attrs: stdenv.mkDerivation (rec {
  name = "${racket.name}-${pname}";
  inherit (attrs) pname;
  racketBuildInputs = attrs.racketBuildInputs or [] ++ self.lib.resolveThinInputs attrs.racketThinBuildInputs or [];
  buildInputs = [ unzip racket ] ++ racketBuildInputs;
  circularBuildInputs = attrs.circularBuildInputs or [];
  circularBuildInputsStr = lib.concatStringsSep " " circularBuildInputs;
  racketBuildInputsStr = lib.concatStringsSep " " racketBuildInputs;
  racketConfigBuildInputs = builtins.filter (input: ! builtins.elem input reverseCircularBuildInputs) racketBuildInputs;
  racketConfigBuildInputsStr = lib.concatStringsSep " " (map (drv: drv.env) racketConfigBuildInputs);
  reverseCircularBuildInputs = attrs.reverseCircularBuildInputs or [];
  src = attrs.src or null;
  srcs = [ src ] ++ attrs.extraSrcs or (map (input: input.src) reverseCircularBuildInputs);
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

      (define racket-lib-dirs
        (append
          (for/list ((name (cons out deps)))
                    (format "~a/share/racket/lib" name))
          (list (format "~a/lib/racket" racket))))

      (define system-lib-dirs
        (string-split (or (getenv "LD_LIBRARY_PATH") '()) ":"))

      (define config-rktd
        `#hash(
          (share-dir . ,(format "~a/share/racket" out))
          (lib-search-dirs . ,(append racket-lib-dirs system-lib-dirs))
          (lib-dir . ,(format "~a/lib/racket" out))
          (bin-dir . ,(format "~a/bin" out))
          (absolute-installation? . #t)
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
      echo >&2 NOTE: This derivation intentionally left blank.
      echo >&2 NOTE: It is a dummy depending on the real circular-dependency package.
      exit 0
    fi

    echo ${racket-cmd}

    mkdir -p $env/share/racket/collects $env/lib $env/bin
    for bootstrap_collection in racket compiler syntax setup openssl ffi file pkg planet; do
      cp -rs $racket/share/racket/collects/$bootstrap_collection \
        $env/share/racket/collects/
    done

    mkdir -p $env/share/racket/pkgs
    for depEnv in $racketConfigBuildInputsStr; do
      if ( shopt -s nullglob; pkgs=($depEnv/share/racket/pkgs/*/); (( ''${#pkgs[@]} > 0 )) ); then
        cp -frs $depEnv/share/racket/pkgs/*/ $env/share/racket/pkgs/
        find $env/share/racket/pkgs -type d -print0 | xargs -0 chmod 755
      fi
    done

    cp -rs $racket/lib/racket $env/lib/racket
    ln -s $racket/include/racket $env/share/racket/include
    find $env/share/racket/collects $env/lib/racket -type d -print0 | xargs -0 chmod 755

    printf > $env/bin/racket "#!${bash}/bin/bash\nexec ${racket-cmd} \"\$@\"\n"
    rm -f $env/lib/racket/gracket
    printf > $env/lib/racket/gracket "#!${bash}/bin/bash\nexec $racket/lib/racket/gracket -G $env/etc/racket -U -X $env/share/racket/collects \"\$@\"\n"
    chmod 555 $env/bin/racket $env/lib/racket/gracket
    PATH=$env/bin:$PATH
    export PLT_COMPILED_FILE_CHECK=exists

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
      ${raco} setup -j $NIX_BUILD_CORES --no-user --no-pkg-deps --fail-fast --only --pkgs $setup_names |&
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
    for depEnv in $racketConfigBuildInputsStr; do
      find $env/share/racket/pkgs -lname "$depEnv/*" -delete
    done
    find $env/share/racket/collects $env/share/racket/pkgs $env/lib/racket $env/bin -type d -empty -delete
    rm $env/share/racket/include
  '';
} // attrs)) suppliedAttrs; in racketDerivation.overrideAttrs (oldAttrs: {
  passthru = oldAttrs.passthru or {} // {
    inherit racketDerivation;
    overrideRacketDerivation = f: self.lib.mkRacketDerivation (suppliedAttrs // (f suppliedAttrs));
  };});


EOM
  )

(define thin-template #<<EOM
self: super: {
~a
}

EOM
)

(define fetchgit-template #<<EOM
  src = fetchgit {
    name = "~a";
    url = "~a";
    rev = "~a";
    sha256 = "~a";
  };
EOM
  )

(define fetchurl-template #<<EOM
  src = fetchurl {
    url = "~a";
    sha1 = "~a";
  };
EOM
  )

(define local-file-template #<<EOM
  src = ~a;
EOM
  )

(define noop-fixed-output-template #<<EOM
  src = self.lib.fixedRacketSource {
    pathname = "~a";
    sha256 = "~a";
  };
EOM
  )

(define derivation-template #<<EOM
self.lib.mkRacketDerivation rec {
  pname = "~a";
~a
  racketBuildInputs = [ ~a ];
  circularBuildInputs = [ ~a ];
  reverseCircularBuildInputs = [ ~a ];
  }
EOM
  )

(define thin-derivation-template #<<EOM
self.lib.mkRacketDerivation rec {
  pname = "~a";
~a
  racketThinBuildInputs = [ ~a ];
  }
EOM
  )
(define (generate-extract-path name url rev path sha256)
  (define git-src (generate-git-src name url rev sha256))
  (format "  src = self.lib.extractPath {~n    path = \"~a\";~n  ~a~n  };" path git-src))

(define (github-url->git-url github-url)
  (match-define (list user repo maybe-rev maybe-path)
    (match github-url
      [(regexp #rx"^github://github.com/([^/]*)/([^/]*)/([^/]*)(/([^/]*))?$"
               (list _ user repo rev _ maybe-path))
       (list user repo rev maybe-path)]
      [(regexp #rx"^[^:]*://github.com/([^/]*)/([^/]*)[.]git/?([?]path=([^#]*))?(#(.*))?$"
               (list _ user repo _ maybe-path _ maybe-rev))
       (list user repo maybe-rev maybe-path)]
      [(regexp #rx"^[^:]*://github.com/([^/]*)/([^/]*)/?([?]path=([^#]*))?(#(.*))?$"
               (list _ user repo _ maybe-path _ maybe-rev))
       (list user repo maybe-rev maybe-path)]
      [(regexp #rx"^[^:]*://github.com/([^/]*)/([^/]*)[.]git/tree/([^?]*)([?]path=(.*))?$"
               (list _ user repo rev _ maybe-path))
       (list user repo rev maybe-path)]
      [(regexp #rx"^[^:]*://github.com/([^/]*)/([^/]*)/tree/([^?]*)([?]path=(.*))?$"
               (list _ user repo rev _ maybe-path))
       (list user repo rev maybe-path)]))
  (~a "git://github.com/" user "/" repo ".git"
      (if (and maybe-path (> (string-length maybe-path) 0)) (~a "?path=" maybe-path) "")
      (if maybe-rev (~a "#" maybe-rev) "")))

(define (maybe-rev->rev rev fallback-rev)
  (cond [(equal? 40 (string-length rev)) rev]
        [else fallback-rev]))

(define (github-url? url)
  (regexp-match #rx"^(git|github|http|https)://github.com/" url))

(define (git-url? url)
  (match url
    [(regexp #rx"^git://") #t]
    [(regexp #rx"^https?://.*#") #t]
    [(regexp #rx"^https?://.*[?]path=") #t]
    [(regexp #rx"^https?://.*[.]git/?$") #t]
    [_ #f]))

(define (discover-git-sha256 url rev)
  (define git-json (with-output-to-string (lambda ()
    (define npg-path (find-executable-path "nix-prefetch-git"))
    (unless npg-path
      (eprintf "ERROR: nix-prefetch-git not found on PATH~n")
      (exit 1))
    (unless (equal? 0 (system*/exit-code npg-path "--no-deepClone" url rev))
            (exit 1)))))
  (define git-dict (with-input-from-string git-json read-json))
  (hash-ref git-dict 'sha256))

(define (discover-path-sha256 pathname)
  (string-trim (with-output-to-string (lambda ()
    (define nh-path (find-executable-path "nix-hash"))
    (unless nh-path
      (eprintf "ERROR: nix-hash not found on PATH~n")
      (exit 1))
    (unless (equal? 0 (system*/exit-code nh-path "--base32" "--type" "sha256" pathname))
            (exit 1))))))

(define discover-store-path
  (let ([store-path #f])
    (lambda ()
      (set! store-path "/nix/store"))))

(define (strip-store-prefix pathname)
  (define store-path (discover-store-path))
  (cond [(string-prefix? pathname store-path)
         (substring pathname (+ (string-length store-path) 34))]
        [else pathname]))

(define (generate-local-file-src pathname)
  (cond [(string-prefix? pathname (discover-store-path))
         (generate-noop-fixed-output-src pathname)]
        [else (format local-file-template pathname)]))

(define (generate-noop-fixed-output-src pathname)
  (format noop-fixed-output-template pathname (discover-path-sha256 pathname)))

(define (url->url-path url)
  (match-define (list noquery-url path) (string-split url "?path="))
  (values noquery-url path))

(define (url-fallback-rev->url-rev-path maybe-github-url fallback-rev)
  (define maybe-fragment-url (if (github-url? maybe-github-url)
                                 (github-url->git-url maybe-github-url)
                                 maybe-github-url))
  (match-define (list-rest maybe-path-url maybe-rev _) (append (string-split maybe-fragment-url "#") (list fallback-rev)))
  (define rev (maybe-rev->rev maybe-rev fallback-rev))
  (define-values (url path)
    (match maybe-path-url
      [(regexp #rx"[?]path=") (url->url-path maybe-path-url)]
      [_ (values maybe-path-url #f)]))
  (values url rev path))

(define (generate-maybe-path-git-src name maybe-github-url fallback-rev sha256)
  (unless sha256
    (raise-argument-error 'generate-maybe-path-git-src
                          "sha256 required to be non-false"
                          3 name maybe-github-url fallback-rev sha256))

  (define-values (url rev path) (url-fallback-rev->url-rev-path maybe-github-url fallback-rev))
  (cond [path
         (generate-extract-path name url rev path sha256)]
        [else
         (generate-git-src name url rev sha256)]))

(define (generate-git-src name url rev sha256)
  (format fetchgit-template name url rev sha256))

(define (derivation #:thin? (thin? #f)
                    name url sha1 dependency-names circular-dependency-names
                    (override-reverse-circular-build-inputs #f)
                    (nix-sha256 #f))

  (define reverse-circular-build-inputs
    (if override-reverse-circular-build-inputs
        override-reverse-circular-build-inputs
        (hash-ref force-reverse-circular-build-inputs name list)))
  (define non-reverse-circular-dependency-names
    (remove* reverse-circular-build-inputs dependency-names))

  (define racket-build-inputs
    (string-join
      (for/list ((name non-reverse-circular-dependency-names))
        (format "self.\"~a\"" name))))
  (define circular-build-inputs
    (string-join
      (for/list ((name circular-dependency-names))
        (format "\"~a\"" name))))
  (define reverse-circular-build-inputs-string
    (string-join
      (for/list ((input reverse-circular-build-inputs))
        (format "\"~a\"" input))))
  (define src
    (cond
      [(and (not url) (not sha1)) ""]
      [(or (github-url? url) (git-url? url))
       (generate-maybe-path-git-src name url sha1 nix-sha256)]
      [(or (string-prefix? url "http://") (string-prefix? url "https://"))
       (format fetchurl-template url sha1)]
      [else
       (generate-local-file-src url)]))
  (define srcs
    (cond
      [(pair? reverse-circular-build-inputs)
       (define srcs-refs (string-join (map (lambda (s) (format "self.\"~a\".src" s)) reverse-circular-build-inputs)))
       (format "~n  extraSrcs = [ ~a ];" srcs-refs)]
      [else ""]))

  (if thin?
    (format thin-derivation-template name (string-join (list src srcs) "") racket-build-inputs)
    (format derivation-template name (string-join (list src srcs) "")
            racket-build-inputs circular-build-inputs
            reverse-circular-build-inputs-string)))

(define (header) header-template)

(define memo-lookup-package hash-ref)
(define memo-lookup-preprocess-package memo-lookup-package)

(define (dependency-name pair-or-string)
  (if (pair? pair-or-string)
      (car pair-or-string)
      pair-or-string))

(define (catalog->let-deps #:flat? (flat? #f) #:thin? (thin? #f) catalog)
  (define names (sort (hash-keys catalog) string<?))
  (define terminal-derivations (if thin?
    '()
    (for/list ((name terminal-package-names))
      (format "  \"~a\" = ~a;" name name))))
  (define derivations
    (for/list ((name (remove* terminal-package-names names)))
      (format "  \"~a\" = ~a;" name (name->derivation #:flat? flat? #:thin? thin? name catalog))))
  (define derivations-on-lines
    (string-join (append terminal-derivations derivations) (format "~n")))
  (format "~a~n" derivations-on-lines))

(define (names->transitive-dependency-names names catalog)
  (append* names (map
    (compose (curryr hash-ref 'transitive-dependency-names) (curry hash-ref catalog))
    names)))

(define (names->transitive-dependency-names-and-cycles names catalog)
  (define transdeps (names->transitive-dependency-names names catalog))
  (define cycles (map
    (compose (curryr hash-ref 'circular-dependencies '()) (curry hash-ref catalog))
    transdeps))
  (sort (remove-duplicates (append* transdeps cycles)) string<?))

(define (name->derivation #:flat? (flat? #f) #:thin? (thin? #f) package-name package-dictionary)
  (define package (memo-lookup-preprocess-package package-dictionary package-name))
  (package->derivation #:flat? flat? #:thin? thin? package package-dictionary))

(define (package->derivation #:flat? (flat? #f) #:thin? (thin? #f) package package-dictionary)
  (define name (hash-ref package 'name))
  (define url (hash-ref package 'source #f))
  (define sha1 (hash-ref package 'checksum #f))
  (define nix-sha256 (hash-ref package 'nix-sha256 #f))
  (define dependency-names (hash-ref package 'dependency-names))
  (define circular-dependency-names (hash-ref package 'circular-dependencies '()))
  (define trans-dep-names (if thin?
    dependency-names
    (hash-ref package 'transitive-dependency-names)))
  (define reverse-circular-dependency-names
    (cond
      [flat?
        (define (expand-reverse-circulars package-name)
          (define package (memo-lookup-package package-dictionary package-name))
          (define rev-circ-dep-names (hash-ref package 'reverse-circular-build-inputs (lambda () '())))
          (append (list package-name) rev-circ-dep-names))
        (remove name (remove* terminal-package-names (remove-duplicates (append*
          (hash-ref package 'reverse-circular-build-inputs (lambda () '()))
          (map expand-reverse-circulars trans-dep-names)))))]
      [else
        (define calculated-reverse-circular
                (hash-ref package 'reverse-circular-build-inputs
                          (lambda () '())))
        (define forced-reverse-circular
                (hash-ref force-reverse-circular-build-inputs name
                          (lambda () '())))
        (remove-duplicates (append calculated-reverse-circular forced-reverse-circular))]))
  (derivation #:thin? thin?
              name url sha1 trans-dep-names (if flat? '() circular-dependency-names)
              reverse-circular-dependency-names
              nix-sha256))

(define (catalog-add-nix-sha256 catalog (package-names #f))
  (define names (if package-names package-names (hash-keys catalog)))

  (for/fold ([url-sha1-memo #hash()] [acc-catalog #hash()] #:result acc-catalog) ([name names])
    (define package (memo-lookup-package catalog name))
    (define url (hash-ref package 'source #f))
    (define sha1 (hash-ref package 'checksum #f))
    (define checksum-error? (hash-ref package 'checksum-error #f))
    (define nix-sha256 (hash-ref package 'nix-sha256 #f))
    (cond
     [checksum-error? (values url-sha1-memo acc-catalog)]
     [(and (not nix-sha256) url sha1
	   (or (github-url? url) (git-url? url)))
      (match-define-values (git-url git-sha1 _) (url-fallback-rev->url-rev-path url sha1))
      (define nix-sha256 (hash-ref url-sha1-memo (cons git-url git-sha1) (lambda () (discover-git-sha256 git-url git-sha1))))
      (define new-package (hash-set package 'nix-sha256 nix-sha256))
      (define new-url-sha1-memo (hash-set url-sha1-memo (cons git-url git-sha1) nix-sha256))
      (values new-url-sha1-memo
              (hash-set acc-catalog name new-package))]
     [else (values url-sha1-memo (hash-set acc-catalog name package))])))

(define (simplify-package-dependency-names catalog)
  (for/hash ([(name package) (in-hash catalog)])
    (define deps (if (member name terminal-package-names)
      '()
      (remove* never-dependency-names
               (map dependency-name (hash-ref package 'dependencies '())))))

    (values name (hash-set package 'dependency-names deps))))

(define (names->deps-and-references #:flat? (flat? #f) package-names catalog)
  (define packages-and-deps (match package-names
    [(list)
     (filter-map (lambda (name) (and (not (hash-ref (hash-ref catalog name) 'checksum-error #f))
                                     name))
                 (hash-keys catalog))]
    [(list package-names ...)
     (names->transitive-dependency-names-and-cycles package-names catalog)]))
  (define catalog-with-sha256 (catalog-add-nix-sha256 catalog packages-and-deps))

  (define package-definitions (catalog->let-deps #:flat? flat? catalog-with-sha256))
  (define prologue (string-append package-definitions (format "}); in~n")))
  (define package-template "racket-packages.\"~a\".overrideAttrs (oldAttrs: { passthru = oldAttrs.passthru or {} // { inherit racket-packages; }; })~n")
  (match package-names
   [(list package-name)
    (string-append prologue (format package-template package-name))]
   [(list package-names ...) ; including the empty list
    (string-append prologue (format "racket-packages~n"))]))

(define (names->nix-function #:flat? (flat? #f) package-names package-dictionary)
  (string-append (header) (names->deps-and-references #:flat? flat? package-names package-dictionary)))

(define (maybe-name->catalog maybe-name catalog process-catalog?)
  (define package-names (if maybe-name
    (names->transitive-dependency-names-and-cycles (list maybe-name) (calculate-package-relations catalog))
    (hash-keys catalog)))
  (define processed-catalog (if process-catalog?
    (catalog-add-nix-sha256 catalog (set-intersect package-names (hash-keys catalog)))
    catalog))

  (for/hash ((name package-names))
    (values name (hash-ref catalog name))))

(define (names->thin-nix-function names packages-dictionary)
  (define catalog (catalog-add-nix-sha256 packages-dictionary names))
  (define package-definitions (catalog->let-deps #:thin? #t catalog))
  (format thin-template package-definitions))

(define (cycle-name cycle)
  (define long-name (string-join cycle "+"))
  (if (<= (string-length long-name) 64)
    long-name
    (string-append (substring long-name 0 61) "...")))

(define (quick-transitive-dependencies name package done catalog)
  (define deps (hash-ref package 'dependency-names))
  (cond
   [(for/and ([dep deps])
      (unless (hash-ref catalog dep #f)
        (raise-user-error (format "Invalid catalog: Package ~a has unresolved dependency ~a.~n"
          name dep)))
      (hash-ref done dep #f))
    (define new-done
      (hash-set done name (hash-set package 'transitive-dependency-names
        (remove-duplicates (append* (cons (hash-ref package 'dependency-names) (map
          (lambda (dep) (hash-ref (hash-ref done dep) 'transitive-dependency-names)) deps)))))))
    (values #hash() new-done)]
   [else
    (define new-todo (for/fold ([new-todo #hash()]) ([todo-name (cons name deps)])
      (if (hash-ref done todo-name #f)
        new-todo
        (hash-set new-todo todo-name (hash-ref catalog todo-name)))))
          (values new-todo done)]))

(define (hash-merge . hs)
  (for/fold ([h (car hs)]) ([k-v (append* (map hash->list (cdr hs)))])
    (match-define (cons k v) k-v)
    (hash-set h k v)))

(define (calculate-transitive-dependencies catalog names)
  (let loop ([todo (make-immutable-hash (map (lambda (name) (cons name (hash-ref catalog name))) names))]
             [done #hash()])
    (cond
     [(hash-empty? todo) done]
     [else
      (define-values (new-todo new-done) (for/fold ([todo #hash()] [done done]) ([(name package) (in-hash todo)])
        (define-values (part-todo part-done) (quick-transitive-dependencies name package done catalog))
        (values (hash-merge todo part-todo) (hash-merge done part-done))))
      (if (and (equal? new-todo todo) (equal? new-done done)) ; only cycles left
          (hash-merge new-todo new-done)
          (loop new-todo new-done))])))

(define (merge-cycles name my-cycle other-cycles found-cycles breadcrumbs memo known-cycles)
  (for/fold
    ([my-cycle my-cycle] [other-cycles other-cycles] [memo memo] [known-cycles known-cycles])
    ([cycle found-cycles])
    (cond
     [(member name cycle)
      (define new-my-cycle (sort (set-union my-cycle cycle) string<?))
      (values new-my-cycle other-cycles
        (set-union memo new-my-cycle)
        (normalize-cycles (list new-my-cycle) known-cycles))]
     [(pair? (set-intersect breadcrumbs cycle))
      (define new-cycle (sort (cons name cycle) string<?))
      (define new-other-cycles (set-union '() (cons new-cycle other-cycles)))
      (values my-cycle new-other-cycles
        (apply set-union (list* memo new-other-cycles))
        (normalize-cycles new-other-cycles known-cycles))]
     [else
      (define new-other-cycles (set-union (list cycle) other-cycles))
      (values my-cycle new-other-cycles
        (apply set-union (list* memo new-other-cycles))
        (normalize-cycles new-other-cycles known-cycles))])))

(define (normalize-cycles . cycleses)
  (define cycles (apply set-union cycleses))
  (remove '() (set-union '() (map
    (lambda (cycle) (for/fold ([acc cycle]) ([other-cycle cycles])
      (if (null? (set-intersect acc other-cycle))
          acc
          (sort (set-union '() acc other-cycle) string<?))))
    cycles))))

(define (find-cycles catalog name package breadcrumbs memo known-cycles)
  (define deps (hash-ref package 'dependency-names))
  (for/fold ([my-cycle '()] [other-cycles '()] [memo memo] [known-cycles known-cycles]
             #:result (append (if (pair? my-cycle) (list my-cycle) '()) other-cycles))
            ([dep-name deps])
    (define dep (hash-ref catalog dep-name))
    (cond
     [(member dep-name breadcrumbs)
      (define new-my-cycle (sort
        (set-union my-cycle (list name dep-name))
        string<?))
      (values new-my-cycle other-cycles
        (set-union memo new-my-cycle)
        (normalize-cycles (list new-my-cycle) other-cycles known-cycles))]
     [(member dep-name memo) ; known cycle, join if relevant
      (define maybe-relevant-cycle (for/or ([cycle known-cycles])
        (define intersection (set-intersect (cons name breadcrumbs) cycle))
        (and (pair? intersection) intersection)))
      (cond
       [maybe-relevant-cycle
        (define new-my-cycle (sort
          (set-union my-cycle (list name) maybe-relevant-cycle)
          string<?))
        (values new-my-cycle other-cycles
          (set-union memo new-my-cycle)
          (normalize-cycles (list new-my-cycle) other-cycles known-cycles))]
       [else
        (values my-cycle other-cycles memo known-cycles)])]
     [(hash-ref dep 'transitive-dependency-names #f) ; a dep with a nice tree, no cycles
      (values my-cycle other-cycles memo known-cycles)]
     [else
      (define found-cycles (find-cycles catalog dep-name dep (cons name breadcrumbs) memo known-cycles))
      (merge-cycles name my-cycle other-cycles found-cycles breadcrumbs memo known-cycles)])))

; assumes catalog has has calculate-transitive-dependencies run on it
(define (calculate-cycles catalog names)
  (for/fold ([cycles '()]) ([name names])
    (define memo (apply set-union (cons '() cycles)))

    (define new-cycles (find-cycles catalog names (hash-ref catalog name) '()
                                    memo cycles))
    (normalize-cycles cycles new-cycles)))

(define (find-transdeps-avoid-cycles catalog name cycles)
  (define my-cycle (or (for/or ([cycle cycles]) (and (member name cycle) cycle)) '()))
  (define package (hash-ref catalog name))
  (define dep-names (remove* my-cycle (hash-ref package 'dependency-names)))

  (define quick-transdeps (hash-ref package 'transitive-dependency-names #f))

  (define-values (new-transdeps new-catalog) (cond
   [quick-transdeps (values quick-transdeps catalog)]
   [else (for/fold
    ([transdeps dep-names] [memo-catalog catalog])
    ([dep-name dep-names])

    (define-values (sub-transdeps new-catalog)
      (find-transdeps-avoid-cycles memo-catalog dep-name cycles))
    (values (set-union transdeps sub-transdeps) new-catalog))]))

  (values
    new-transdeps
    (hash-set new-catalog name (hash-set package 'transitive-dependency-names new-transdeps))))

(define (calculate-package-relations catalog (package-names '()))
  (define names (if (pair? package-names)  package-names (hash-keys catalog)))
  (define catalog-with-transdeps (calculate-transitive-dependencies catalog names))

  (define cycles (calculate-cycles catalog names))

  (define catalog-with-transdeps-and-cycles (for/fold ([acc-catalog catalog]) ([name (append* names cycles)])
    (define circdeps (or (for/or ([cycle cycles]) (if (member name cycle) cycle #f)) '()))
    (define-values (transdeps new-catalog) (find-transdeps-avoid-cycles acc-catalog name cycles))

    (hash-set new-catalog name (hash-set* (hash-ref new-catalog name)
      'transitive-dependency-names (remove* circdeps transdeps)
      'circular-dependencies circdeps))))

  (define reified-cycles (for/hash ([cycle cycles])
    (define name (cycle-name cycle))
    (define cycle-packages (map (curry hash-ref catalog-with-transdeps-and-cycles) cycle))
    (define package (make-immutable-hash (list
      (cons 'name name)
      (cons 'reverse-circular-build-inputs cycle)
      (cons 'dependency-names
            (sort (apply set-union
                    (map (lambda (pkg) (hash-ref pkg 'dependency-names)) cycle-packages))
                  string<?))
      (cons 'transitive-dependency-names
            (sort (apply set-union
                    (map (lambda (pkg) (hash-ref pkg 'transitive-dependency-names (lambda ()
                                         (error (format "pkg ~a no transdeps~n" (hash-ref pkg 'name))))))
                    cycle-packages))
                  string<?)))))
    (values name package)))

  (define catalog-with-reified-cycles (let loop
    ([catalog (hash-merge catalog-with-transdeps-and-cycles reified-cycles)])
    (define (lookup-package name) (hash-ref catalog name))

    (define names-with-transdeps-and-cycles
      (apply set-union (list* names (map cycle-name cycles) (append cycles (map
        (lambda (name) (hash-ref (lookup-package name) 'transitive-dependency-names))
          (append* names cycles))))))

    (define new-catalog (for/fold ([catalog catalog]) ([name names-with-transdeps-and-cycles])
      (define package (lookup-package name))
      (define transdeps (hash-ref package 'transitive-dependency-names))
      (define cycles (remove '() (remove-duplicates (map
        (lambda (name) (hash-ref (lookup-package name) 'circular-dependencies '()))
        (cons name transdeps)))))
      (define cycle-names (map cycle-name cycles))
      (define reified-cycle-transdeps (append* cycle-names (map
        (compose (curryr hash-ref 'transitive-dependency-names) (curry hash-ref reified-cycles))
        cycle-names)))
      (define normalized-transdeps (remove name (sort (set-union transdeps reified-cycle-transdeps) string<?)))
      (hash-set catalog name (hash-set package 'transitive-dependency-names normalized-transdeps))))

    (if (equal? catalog new-catalog)
        (for/hash ([name names-with-transdeps-and-cycles]) (values name (lookup-package name)))
        (loop new-catalog))))

  catalog-with-reified-cycles)

(module+ main
  (define catalog-paths #f)
  (define flat? #f)
  (define export-catalog? #f)
  (define process-catalog? #t)
  (define thin? #f)

  (define package-names-or-paths
    (command-line
      #:program "racket2nix"
      #:usage-help "Except with --export-catalog, at least one package name or path is required as an argument."
                   "A path is an argument that contains at least one '/'. A path is treated as the path to a racket\
 package, which will be named as the part of the path after the last '/'."
                   "A package name is an argument with no '/'. It is looked up in the provided catalogs."
                   "If several paths are given, the first one is to the main package to build, and the others are\
 used for defining the paths to those packages and inserted into the catalog for the first package to use as\
 dependencies. Providing several package names makes no sense."
      #:once-each
      [("--test")
       "Ignore everything else and just run the tests."
       (if (> ((dynamic-require 'rackunit/text-ui 'run-tests)
               (dynamic-require 'nix/racket2nix-test 'suite))
              0)
           (exit 1)
           (exit 0))]
      [("--no-process-catalog")
       "When exporting a catalog, do not process it, just merge the --catalog inputs and export as they are."
       (set! process-catalog? #f)]
      #:once-any
      [("--export-catalog")
       "Instead of outputting a nix expression, output a pre-processed catalog, with the nix-sha256 looked up and\
 added. If a package name or path is given, only the subset of the catalog that includes that package and its dependencies\
 will be output. If several paths are given, the ones after the first one are used for extending the catalog, just like\
 in the main use case. Providing several package names makes no sense."
       (set! export-catalog? #t)]
      [("--thin")
       "Do not read any catalogs, do not output a full stand-alone nix expression, just output an expression suitable\
 for extending racket-catalog.nix, and which assumes that any dependencies will be resolved by the catalog (or its\
 extensions)."
       (set! thin? #t)]
      [("--flat")
       "Do not try to install each dependency separately, just install and setup all dependencies in the main derivation."
       (set! flat? #t)]
      #:multi
      ["--catalog"
       catalog-path
       "Read from this catalog instead of downloading catalogs. Can be provided multiple times to use several catalogs.\
 Later given catalogs have lower precedence."
       (set! catalog-paths (cons catalog-path (or catalog-paths '())))]
      #:args package-name-or-path
      package-name-or-path))

  (define pkg-details (cond
    [thin? (make-hash)]
    [catalog-paths
      (hash-copy (for/hash
        ([kv (append* (for/list
          ([catalog-path catalog-paths])
          (hash->list (call-with-input-file* catalog-path read))))])
        (match-define (cons k v) kv)
        (values k v)))]
    [else
      (eprintf "Fetching package catalogs...~n")
      (get-all-pkg-details-from-catalogs)]))

  (define package-names (map (lambda (package-name-or-path) (cond
    [(string-contains? package-name-or-path "/")
     (define name (string-replace (strip-store-prefix package-name-or-path) #rx".*/" ""))
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
    package-names-or-paths))

  (define catalog-with-package-dependency-names
    (simplify-package-dependency-names pkg-details))

  (cond
    [thin?
     (display (names->thin-nix-function package-names catalog-with-package-dependency-names))]
    [export-catalog?
     (write (maybe-name->catalog
       (if (= 1 (length package-names)) (car package-names) #f)
       catalog-with-package-dependency-names process-catalog?))]
    [else
     (display (names->nix-function #:flat? flat? package-names
                                   (calculate-package-relations catalog-with-package-dependency-names package-names)))]))
