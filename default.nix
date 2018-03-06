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

let
  _racket-lib = racket-lib;
  _base = stdenv.mkDerivation rec {
  name = "base";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/6.12/pkgs/base.zip";
    sha1 = "842e2b328663a51a11b18ef6c0f971647227a231";
  };

  buildInputs = [ unzip racket _racket-lib ];
  circularBuildInputs = [  ];
  circularBuildInputsStr = stdenv.lib.concatStringsSep " " circularBuildInputs;
  reverseCircularBuildInputs = [  ];
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
  (links-search-files . ( "$out/share/racket/links.rktd" "${_racket-lib.out}/share/racket/links.rktd" ))
  (pkgs-search-dirs . ( "$out/share/racket/pkgs" "${_racket-lib.out}/share/racket/pkgs" ))
  (collects-search-dirs . ( "$out/share/racket/collects" "${_racket-lib.out}/share/racket/collects" ))
  (doc-search-dirs . ( "$out/share/racket/doc" "${_racket-lib.out}/share/racket/doc" ))
  (absolute-installation . #t)
  (installation-name . ".")
)
  '';

  installPhase = ''
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
              ${raco} setup --no-user --no-pkg-deps --fail-fast --only --pkgs ''${install_name#./}
              ;;
          esac
        done
      fi
    fi
    find $out/share/racket/collects -lname '${_racket-lib.out}/share/racket/collects/*' -delete
    find $out/share/racket/collects -type d -empty -delete
  '';
};
  _nix = stdenv.mkDerivation rec {
  name = "nix";
  src = ./nix;

  buildInputs = [ unzip racket _racket-lib _base ];
  circularBuildInputs = [  ];
  circularBuildInputsStr = stdenv.lib.concatStringsSep " " circularBuildInputs;
  reverseCircularBuildInputs = [  ];
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
  (links-search-files . ( "$out/share/racket/links.rktd" "${_racket-lib.out}/share/racket/links.rktd" "${_base.out}/share/racket/links.rktd" ))
  (pkgs-search-dirs . ( "$out/share/racket/pkgs" "${_racket-lib.out}/share/racket/pkgs" "${_base.out}/share/racket/pkgs" ))
  (collects-search-dirs . ( "$out/share/racket/collects" "${_racket-lib.out}/share/racket/collects" "${_base.out}/share/racket/collects" ))
  (doc-search-dirs . ( "$out/share/racket/doc" "${_racket-lib.out}/share/racket/doc" "${_base.out}/share/racket/doc" ))
  (absolute-installation . #t)
  (installation-name . ".")
)
  '';

  installPhase = ''
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
              ${raco} setup --no-user --no-pkg-deps --fail-fast --only --pkgs ''${install_name#./}
              ;;
          esac
        done
      fi
    fi
    find $out/share/racket/collects -lname '${_racket-lib.out}/share/racket/collects/*' -delete
    find $out/share/racket/collects -type d -empty -delete
  '';
};
in
_nix
