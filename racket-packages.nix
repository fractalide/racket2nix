{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
, lib ? stdenv.lib
, cacert ? pkgs.cacert
, fetchurl ? pkgs.fetchurl
, fetchgit ? pkgs.fetchgit
, racket ? pkgs.racket-minimal
, racket-lib ? racket // { lib = racket.out; }
, unzip ? pkgs.unzip
, bash ? pkgs.bash
, findutils ? pkgs.findutils
, gnused ? pkgs.gnused
, makeSetupHook ? pkgs.makeSetupHook
, time ? pkgs.time
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
  preferLocalBuild = true;
  allowSubstitutes = false;
} ''
  cp -a $pathname $out && exit
  echo ERROR: Unable to find source for $name: $pathname
'';

lib.makeConfigRktd = builtins.toFile "make-config-rktd.rkt" ''
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

lib.makeRacket = makeSetupHook { substitutions = rec { inherit (self.pkgs) bash findutils which; shell = bash + /bin/bash;
                                                       inherit (self.lib) makeConfigRktd; }; }
                               (builtins.toFile "makeRacket.sh" ''
  function makeRacket() {
    local -
    set -euo pipefail
    local out=$1
    local racket=$2
    shift; shift
    local deps=$*

    mkdir -p $out/bin $out/etc/racket $out/lib $out/share/racket/pkgs
    [ -d $out/share/racket/collects ] || cp -rs $racket/share/racket/collects $out/share/racket/
    [ -d $out/share/racket/include ] || ln -s $racket/include/racket $out/share/racket/include
    [ -d $out/lib/racket ] || cp -rs $racket/lib/racket $out/lib/racket
    @findutils@/bin/find $out/lib/racket -type d -exec chmod 755 {} +

    cat > $out/bin/racket.new <<EOF
  #!@shell@
  exec $racket/bin/racket -G $out/etc/racket -U -X $out/share/racket/collects "\$@"
  EOF
    mv $out/bin/racket{.new,}

    cat > $out/lib/racket/gracket.new <<EOF
  #!@shell@
  exec $racket/lib/racket/gracket -G $out/etc/racket -U -X $out/share/racket/collects "\$@"
  EOF
    mv $out/lib/racket/gracket{.new,}

    cat > $out/bin/raco.new <<EOF
  #!@shell@
  exec $racket/bin/racket -G $out/etc/racket -U -X $out/share/racket/collects -N raco -l- raco "\$@"
  EOF
    mv $out/bin/raco{.new,}

    chmod 555 $out/bin/racket $out/bin/raco $out/lib/racket/gracket

    racket @makeConfigRktd@ $out $racket $deps > $out/etc/racket/config.rktd
  }

  function setupRacket() {
    local lib=$1

    $lib/bin/raco setup --no-docs --no-install --no-launcher --no-post-install --no-zo
  }

  function racoPkgInstallCopy() {
    local lib=$1
    shift

    $lib/bin/raco pkg install --no-setup --copy --deps fail --fail-fast --scope installation $* \
      &> >(sed  -Ee '/warning: tool "(setup|pkg|link)" registered twice/d')
  }

  function racoSetup() {
    local lib=$1
    shift

    $lib/bin/raco setup -j $NIX_BUILD_CORES --no-user --no-pkg-deps --fail-fast --only --pkgs $* \
      &> >(sed -ne '/updating info-domain/,$p')
  }
'');

lib.mkRacketDerivation = suppliedAttrs: let racketDerivation = lib.makeOverridable (attrs: stdenv.mkDerivation (rec {
  name = "${racket.name}-${pname}";
  inherit (attrs) pname;
  racketBuildInputs = lib.lists.unique (
    attrs.racketThinBuildInputs or [] ++
    (builtins.concatLists (builtins.catAttrs "racketBuildInputs" attrs.racketThinBuildInputs)));
  buildInputs = [ cacert unzip racket self.lib.makeRacket ] ++ racketBuildInputs;
  circularBuildInputs = attrs.circularBuildInputs or [];
  circularBuildInputsStr = lib.concatStringsSep " " circularBuildInputs;
  racketBuildInputsStr = lib.concatStringsSep " " racketBuildInputs;
  racketConfigBuildInputs = builtins.filter (input: ! builtins.elem input reverseCircularBuildInputs) racketBuildInputs;
  racketConfigBuildInputsStr = lib.concatStringsSep " " (map (drv: drv.lib) racketConfigBuildInputs);
  reverseCircularBuildInputs = attrs.reverseCircularBuildInputs or [];
  src = attrs.src or null;
  srcs = [ src ] ++ attrs.extraSrcs or (map (input: input.src) reverseCircularBuildInputs);
  doInstallCheck = attrs.doInstallCheck or false;
  inherit racket;
  outputs = [ "out" "lib" ];

  PLT_COMPILED_FILE_CHECK = "exists";

  phases = "unpackPhase patchPhase installPhase fixupPhase installCheckPhase";
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

  maxFileDescriptors = 3072;

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

    makeRacket $lib $racket $racketConfigBuildInputsStr
    setupRacket $lib
    mkdir -p $out

    if [ -n "${circularBuildInputsStr}" ]; then
      echo >&2 NOTE: This derivation intentionally left blank.
      echo >&2 NOTE: It is a dummy depending on the real circular-dependency package.
      exit 0
    fi

    # install and link us
    install_names=""
    setup_names=""
    for install_info in ./*/info.rkt; do
      install_name=''${install_info%/info.rkt}
      if $lib/bin/racket -e "(require pkg/lib)
                           (define name \"''${install_name#./}\")
                           (for ((scope (get-all-pkg-scopes)))
                             (when (member name (installed-pkg-names #:scope scope))
                                   (eprintf \"WARNING: ~a already installed in ~a -- not installing~n\"
                                            name scope)
                                   (exit 1)))"; then
        install_names+=" $install_name"
        setup_names+=" ''${install_name#./}"
      fi
    done

    if [ -n "$install_names" ]; then
      racoPkgInstallCopy $lib $install_names

      if ! racoSetup $lib $setup_names; then
        echo >&2 Quick install failed, falling back to slow install.

        dep_install_names=""
        for depEnv in $racketConfigBuildInputsStr; do
          if ( shopt -s nullglob; pkgs=($depEnv/share/racket/pkgs/*/); (( ''${#pkgs[@]} > 0 )) ); then
            for dep_install_name in $depEnv/share/racket/pkgs/*/; do
              dep_install_names+=" $dep_install_name"
            done
          fi
        done

        # All our dependencies, writable
        buildEnv=$(mktemp -d --tmpdir XXXXXX-$pname-env)
        makeRacket $buildEnv $racket
        racoPkgInstallCopy $buildEnv $dep_install_names

        chmod -R 755 $lib
        rm -rf $lib
        makeRacket $lib $racket $buildEnv
        setupRacket $lib
        racoPkgInstallCopy $lib $install_names
        racoSetup $lib $setup_names
        # Pretend our workaround never happened, retain setup's output
        makeRacket $lib $racket $racketConfigBuildInputsStr
      fi
    fi

    mkdir -p $out/bin
    for launcher in $lib/bin/*; do
      if ! [[ ''${launcher##*/} = racket || ''${launcher##*/} = raco ]]; then
        ln -s "$launcher" "$out/bin/''${launcher##*/}"
      fi
    done

    eval "$restore_pipefail"
    runHook postInstall

    find $lib/share/racket/collects $lib/share/racket/pkgs $lib/lib/racket -type d -exec chmod 755 {} +
    find $lib/share/racket/collects $lib/lib/racket -lname "$racket/*" -delete
    for depEnv in $racketConfigBuildInputsStr; do
      find $lib/share/racket/pkgs -lname "$depEnv/*" -delete
    done
    find $lib/share/racket/collects $lib/share/racket/pkgs $lib/lib/racket $lib/bin -type d -empty -delete
    rm $lib/share/racket/include

    PATH=$lib/bin:$PATH
  '';

  installCheckFileFinder = ''find "$lib"/share/racket/pkgs/"$pname" -name '*.rkt' -print0'';
  installCheckPhase = if !doInstallCheck then null else let
    testConfigBuildInputs = [ self.compiler-lib ] ++ self.compiler-lib.racketBuildInputs;
    testConfigBuildInputsStr = lib.concatStringsSep " " (map (drv: drv.lib) testConfigBuildInputs);
  in ''
    runHook preInstallCheck
    export testEnv=$(mktemp -d --tmpdir XXXXXX-$pname-testEnv)
    if [ -v buildEnv ]; then
      makeRacket $testEnv $racket $lib $buildEnv ${testConfigBuildInputsStr}
    else
      makeRacket $testEnv $racket $lib $racketConfigBuildInputsStr ${testConfigBuildInputsStr}
    fi

    setupRacket $testEnv
    racoSetup $testEnv $setup_names

    ${findutils}/bin/xargs -I {} -0 -n 1 -P ''${NIX_BUILD_CORES:-1} bash -c '
      set -eu
      testpath=''${1#*/share/racket/pkgs/}
      logdir="$testEnv/log/''${testpath%/*}"
      mkdir -p "$logdir"
      timeout ''${installCheckTimeout:-60} ${time}/bin/time -f "%e s $testpath" $testEnv/bin/raco test -q "$1" \
        &> >(grep -v -e "warning: tool .* registered twice" -e "@[(]test-responsible" | tee "$logdir/''${1##*/}")
    ' 'xargs raco test {}' {} < <(runHook installCheckFileFinder)
    runHook postInstallCheck
  '';
} // attrs)) suppliedAttrs; in racketDerivation.overrideAttrs (oldAttrs: {
  passthru = oldAttrs.passthru or {} // {
    inherit racketDerivation;
    overrideRacketDerivation = f: self.lib.mkRacketDerivation (suppliedAttrs // (f suppliedAttrs));
  };});

  "racket-lib" = racket-lib;
  "1d6" = self.lib.mkRacketDerivation rec {
  pname = "1d6";
  src = fetchgit {
    name = "1d6";
    url = "git://github.com/jessealama/1d6.git";
    rev = "ae3bf1fc265bd1815dc8f9d6bbb153afdbf3a53d";
    sha256 = "00sk1dwi76lxgkyxrk8q4w1dqmqsmvbsv6b5n4px7fdjlz7c3j18";
  };
  racketThinBuildInputs = [ self."base" self."brag" self."beautiful-racket-lib" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."beautiful-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2019-nCov-report" = self.lib.mkRacketDerivation rec {
  pname = "2019-nCov-report";
  src = fetchgit {
    name = "2019-nCov-report";
    url = "git://github.com/yanyingwang/2019-nCov-report.git";
    rev = "50bafe7b809383ecbe8dd8d0256768e76c10f2bc";
    sha256 = "1931qxq5q2ca89j8zs9mvr34nmhb4vj709inrlqvxshldi46172g";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."r6rs-lib" self."gregor-lib" self."smtp" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2048" = self.lib.mkRacketDerivation rec {
  pname = "2048";
  src = fetchgit {
    name = "2048";
    url = "git://github.com/LiberalArtist/2048.git";
    rev = "512822ddd7969335b1c91f9f6b9e23c8cf7160f6";
    sha256 = "1pwzc4bmxcwjfnnvzw3ap406p032kkjabm6cs7fm6al90wizraf3";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."icns" self."pict-lib" self."string-constants-lib" self."typed-racket-lib" self."typed-racket-more" self."racket-doc" self."scribble-lib" self."rackunit-lib" self."rackunit-typed" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d" = self.lib.mkRacketDerivation rec {
  pname = "2d";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/2d.zip";
    sha1 = "74ea5fc2d99e095b3b5609197f14607a51b3982c";
  };
  racketThinBuildInputs = [ self."2d-lib" self."2d-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-doc" = self.lib.mkRacketDerivation rec {
  pname = "2d-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/2d-doc.zip";
    sha1 = "32d3f9d1b8d19893f99ee4d1df46ac999f711a41";
  };
  racketThinBuildInputs = [ self."base" self."2d-lib" self."scribble-lib" self."racket-doc" self."syntax-color-doc" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-lib" = self.lib.mkRacketDerivation rec {
  pname = "2d-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/2d-lib.zip";
    sha1 = "95358557e07352fc2600795d5e21ed3928950dd9";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-test" = self.lib.mkRacketDerivation rec {
  pname = "2d-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/2d-test.zip";
    sha1 = "aa9ea714426df96a552851933a13fe185ca5b852";
  };
  racketThinBuildInputs = [ self."base" self."2d-lib" self."racket-index" self."rackunit-lib" self."option-contract-lib" self."at-exp-lib" self."gui-lib" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2htdp-typed" = self.lib.mkRacketDerivation rec {
  pname = "2htdp-typed";
  src = fetchgit {
    name = "2htdp-typed";
    url = "git://github.com/lexi-lambda/racket-2htdp-typed.git";
    rev = "b46c957f0ad7490bc7b0f01da0e80380f34cac2d";
    sha256 = "0kdrbxmy2bx9rj9is7nk168nc3rx77yig2b8kpyv1cjgmfhk53za";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."htdp-lib" self."typed-racket-lib" self."typed-racket-more" self."unstable-list-lib" self."unstable-contract-lib" self."scribble-lib" self."racket-doc" self."htdp-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "3d-model" = self.lib.mkRacketDerivation rec {
  pname = "3d-model";
  src = fetchurl {
    url = "http://code_man.cybnet.ch/racket/3d-model.zip";
    sha1 = "078e2dcd4a62eb026dedbdf3fdeaef3efc8e9925";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "3s" = self.lib.mkRacketDerivation rec {
  pname = "3s";
  src = fetchgit {
    name = "3s";
    url = "git://github.com/jeapostrophe/3s.git";
    rev = "b84991a59ced42303420c58d71702ed9db6a2644";
    sha256 = "16cbdgflydjqg24zgwgspa4w8ga8k07gph6ydc5hhllmnilmpi4z";
  };
  racketThinBuildInputs = [ self."lux" self."base" self."openal" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ANU-Web-Quantum-RNG" = self.lib.mkRacketDerivation rec {
  pname = "ANU-Web-Quantum-RNG";
  src = fetchgit {
    name = "ANU-Web-Quantum-RNG";
    url = "https://bitbucket.org/Tetsumi/anu-web-quantum-rng.git";
    rev = "e8de6a730ecdf8665dfa0e01540b199d51d2667a";
    sha256 = "1aq4m8zsxry4lrmyckcgc36mqsrrdl5nk4xm53aa4pzzhdq887fb";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Adapton" = self.lib.mkRacketDerivation rec {
  pname = "Adapton";
  src = fetchgit {
    name = "Adapton";
    url = "git://github.com/plum-umd/adapton.racket.git";
    rev = "9ddfec8a22809cfb37fbbd8871a088fc3bd51787";
    sha256 = "1bzazr6gfm220an2xhrig379rhanw9ayllig6wbifi9qfdziyl4f";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Agatha" = self.lib.mkRacketDerivation rec {
  pname = "Agatha";
  src = fetchgit {
    name = "Agatha";
    url = "git://github.com/joseildofilho/Agatha-Lang.git";
    rev = "de9e340b97dbb22677dc3ba74d6ec8826bf9af90";
    sha256 = "1d7vqw0smf5106dawii0sl1vcbic09c3bxyz9xkrgnm5xzll5qaq";
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."brag-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "DrRacketTheme" = self.lib.mkRacketDerivation rec {
  pname = "DrRacketTheme";
  src = fetchgit {
    name = "DrRacketTheme";
    url = "git://github.com/Syntacticlosure/DrRacketTheme.git";
    rev = "6ee86a2b2824f755bdaf771c788559d9cab7639c";
    sha256 = "09p0aqw054i178pz60z3xglpnhbm2ns4j42z34gsci5y2grlzkz5";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."gui-lib" self."pict-lib" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Drrackgit" = self.lib.mkRacketDerivation rec {
  pname = "Drrackgit";
  src = fetchgit {
    name = "Drrackgit";
    url = "git://github.com/bbusching/drrackgit.git";
    rev = "7c2836bf5a08858eca7d32959d8ae3fd90a5defe";
    sha256 = "0590q06amx6slxmnfzban64q4x98vpnsr8fr023fkhs0rs97cfn6";
  };
  racketThinBuildInputs = [ self."libgit2" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Fairylog" = self.lib.mkRacketDerivation rec {
  pname = "Fairylog";
  src = fetchgit {
    name = "Fairylog";
    url = "git://github.com/pezipink/fairylog.git";
    rev = "f0c1d0d82e2ed9ff02486ddd91a0ede5c5483ef7";
    sha256 = "10m9y8qp71qd7njwsigl23w1v5zxs1ysirmflwqgdmi3vnp8969c";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Funktionuckelt" = self.lib.mkRacketDerivation rec {
  pname = "Funktionuckelt";
  src = fetchgit {
    name = "Funktionuckelt";
    url = "git://github.com/DondiBronson/Funktionuckelt.git";
    rev = "c465bd2afced654c4bf08b70740cd2be6a383a62";
    sha256 = "1xsw2ls5671mc3n8kxpv8in6x1bfdbww8jgb6w6xaxd45qnv3s6c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "GLPK" = self.lib.mkRacketDerivation rec {
  pname = "GLPK";
  src = fetchgit {
    name = "GLPK";
    url = "git://github.com/jbclements/glpk.git";
    rev = "ff20adf1ea0f6792b6a858aa421c79ce22a8fd5d";
    sha256 = "0dhlrrfy3w5qg05cafsi34s43fz5wn7lxc6542dxrlrpbhy4vv4b";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."racket-doc" self."scribble-lib" self."scribble-math" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "HoLy" = self.lib.mkRacketDerivation rec {
  pname = "HoLy";
  src = fetchgit {
    name = "HoLy";
    url = "git://github.com/nihirash/holy.git";
    rev = "e6574beb88937357cb73e834dacf10ceb1805495";
    sha256 = "0xk9dxwslqg371k0xh6my557vzskgcsi8zv543hk0bzpivn6b8yx";
  };
  racketThinBuildInputs = [ self."web-server" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Packrat" = self.lib.mkRacketDerivation rec {
  pname = "Packrat";
  src = fetchgit {
    name = "Packrat";
    url = "git://github.com/simonhaines/packrat.git";
    rev = "b439a1d997df7bc6cf5d5c4f349355d84cb89e03";
    sha256 = "0v5f6bfxfsvq0ip95wvyphlz7yf89w1jx2ww8rz1vpsy61yynkvz";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."srfi-lite-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Quaternion" = self.lib.mkRacketDerivation rec {
  pname = "Quaternion";
  src = fetchgit {
    name = "Quaternion";
    url = "git://github.com/APOS80/Quaternion.git";
    rev = "96591d338f423f741f712150d0e20da93500f1e8";
    sha256 = "03pr0fk9lyyizdzxc7ilvgcdjcrccbnkb8jnhx0z9x0wyyv7cgmx";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."math-lib" self."typed-racket-doc" self."racket-doc" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "Relation" = self.lib.mkRacketDerivation rec {
  pname = "Relation";
  src = fetchgit {
    name = "Relation";
    url = "git://github.com/countvajhula/relation.git";
    rev = "77c7536de0da67c42af39f2da5abb17ff716f1f2";
    sha256 = "0f62rx4k54srq2f1bhfsnypsijcc6mhnawnsm5lkl1q4lrg8xak4";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."algebraic" self."describe" self."point-free" self."threading-lib" self."version-case" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."sugar" self."collections-doc" self."functional-doc" self."rackjure" self."sandbox-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "SAT" = self.lib.mkRacketDerivation rec {
  pname = "SAT";
  src = fetchgit {
    name = "SAT";
    url = "git://github.com/Kraks/SAT.rkt.git";
    rev = "f7d02e94bea4e5d2e1efcdf5678fc297b23957f5";
    sha256 = "1bxbl98g1c57gxkrm29xbr9pkkl5spmj202h3prn1dhwc1wy8j6r";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "SSE" = self.lib.mkRacketDerivation rec {
  pname = "SSE";
  src = fetchgit {
    name = "SSE";
    url = "git://github.com/quxo/SSE.git";
    rev = "b03b5cbfea7836a18b31267459a409a23cf5de6e";
    sha256 = "0gkw4iy1a1l1x23fzsfr7jgzna62n1kghl7klgclsb750v4d54bj";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "_" = self.lib.mkRacketDerivation rec {
  pname = "_";
  src = fetchgit {
    name = "_";
    url = "git://github.com/LeifAndersen/racket-_.git";
    rev = "e687a8eaf4ef62b97ad5d37f6fd09cb684c7d101";
    sha256 = "0dkyj3np4w5wxyv940lv26myra3fw94dzvyp0v5265qlspmfpsjj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "_-exp" = self.lib.mkRacketDerivation rec {
  pname = "_-exp";
  src = fetchgit {
    name = "_-exp";
    url = "git://github.com/LiberalArtist/_-exp.git";
    rev = "7bb9c5c53eafc4e7c23d7da7f015ae2027ec50ca";
    sha256 = "16519qlpd15q0wmrxd68al1kw9sf789q7rvpbbn39a1wfkflywhy";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."syntax-color-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" self."web-server-doc" self."adjutor" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "abnf" = self.lib.mkRacketDerivation rec {
  pname = "abnf";
  src = fetchgit {
    name = "abnf";
    url = "git://github.com/samth/abnf.git";
    rev = "71bc4739a0b2aa22aa42ad905ba7de5c3e2c7f79";
    sha256 = "11ji0kkdcgmz8790rbrjx5s4a0gnbqbfay2gqv8svjw1g8c2886j";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "acl2s-scribblings" = self.lib.mkRacketDerivation rec {
  pname = "acl2s-scribblings";
  src = fetchgit {
    name = "acl2s-scribblings";
    url = "git://github.com/AlexKnauth/acl2s-scribblings.git";
    rev = "5df28624fe8dcf2286ae7e9896ab59b9e4fb7400";
    sha256 = "0igfcs4d5s17y6y2lknj4ikfgskp7zawd3ckcr9i8rg7796pfklv";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."syntax-classes-lib" self."syntax-class-or" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "acmart" = self.lib.mkRacketDerivation rec {
  pname = "acmart";
  src = self.lib.extractPath {
    path = "scribble-lib";
    src = fetchgit {
    name = "acmart";
    url = "git://github.com/racket/scribble.git";
    rev = "13798906ceedfc1473643d06f4f98d4f372e889e";
    sha256 = "1sv5wk7ajh4caxmk2wr3nx8r0hnc6raj52slam3s9vdbin8q80nq";
  };
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."scribble-text-lib" self."scribble-html-lib" self."planet-lib" self."net-lib" self."at-exp-lib" self."draw-lib" self."syntax-color-lib" self."sandbox-lib" self."typed-racket-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "acmsmall" = self.lib.mkRacketDerivation rec {
  pname = "acmsmall";
  src = fetchgit {
    name = "acmsmall";
    url = "git://github.com/stamourv/acmsmall-scribble.git";
    rev = "15a951e4dff06856862d2a87afd032b983a705be";
    sha256 = "0vikhn7ijdgj313m8nnx8j90w94hada2vhiv8yj785i4h45rfqlw";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "adjutor" = self.lib.mkRacketDerivation rec {
  pname = "adjutor";
  src = fetchgit {
    name = "adjutor";
    url = "git://github.com/LiberalArtist/adjutor.git";
    rev = "c6915fe38222574400b74172d4753aab60f0d3ec";
    sha256 = "0r2rq819ap7s5ypsbpxrriib885hff9ay5isdqd6qr8za8c70mbr";
  };
  racketThinBuildInputs = [ self."base" self."static-rename-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."rackunit-spec" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "admiral-edu-server" = self.lib.mkRacketDerivation rec {
  pname = "admiral-edu-server";
  src = fetchgit {
    name = "admiral-edu-server";
    url = "git://github.com/jbclements/admiral-edu-server.git";
    rev = "79c2778dd43d07e92ab02fb75955ec6060ed6861";
    sha256 = "14d5wh3d8z4lbny34bs6mbk3ghw735mrxbxnv42d44cz2hyfba15";
  };
  racketThinBuildInputs = [ self."aws" self."base" self."db-lib" self."net-lib" self."typed-racket-lib" self."web-server-lib" self."yaml" self."rackunit-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "affix" = self.lib.mkRacketDerivation rec {
  pname = "affix";
  src = fetchgit {
    name = "affix";
    url = "git://github.com/morcmarc/affix.git";
    rev = "32a8e88e8547227d473013d8f90f41f6b5665b69";
    sha256 = "08a6jbfadfd1iiapyz9xbkhp1ix74mxls7byflfdl33y3khhmh65";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "afl" = self.lib.mkRacketDerivation rec {
  pname = "afl";
  src = fetchgit {
    name = "afl";
    url = "git://github.com/AlexKnauth/afl.git";
    rev = "13b5f8c6c71f0eb66a4f1e71f295bfda88f526bb";
    sha256 = "0wq88cxahrbk614dl2ylsy84pq2as08s96xwivx6wrqn5pcjwrwq";
  };
  racketThinBuildInputs = [ self."base" self."hygienic-reader-extension" self."at-exp-lib" self."rackjure" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" self."scribble-code-examples" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aful" = self.lib.mkRacketDerivation rec {
  pname = "aful";
  src = fetchgit {
    name = "aful";
    url = "git://github.com/jsmaniac/aful.git";
    rev = "bbdf6dcc6ed8787eb85c3a7938604879a361b9f8";
    sha256 = "1ipfn1bpz5pp3mfbxp9r8fkvpb7qydsmr7p6vnadva6kiggk70iq";
  };
  racketThinBuildInputs = [ self."base" self."hygienic-reader-extension" self."at-exp-lib" self."rackjure" self."rackunit-lib" self."phc-toolkit" self."scribble-enhanced" self."scribble-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" self."scribble-code-examples" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "agile" = self.lib.mkRacketDerivation rec {
  pname = "agile";
  src = fetchgit {
    name = "agile";
    url = "git://github.com/bennn/agile.git";
    rev = "fdd3b7388d5485cee179cdbc172c9752b7a0cf73";
    sha256 = "19mzyvhpbapdql313lw5zyg9canp4j1988zk1x7phrpj7jz1lf00";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexis-collection-lens" = self.lib.mkRacketDerivation rec {
  pname = "alexis-collection-lens";
  src = fetchgit {
    name = "alexis-collection-lens";
    url = "git://github.com/lexi-lambda/alexis-collection-lens.git";
    rev = "4f91587e8a5728b02c1ea9af9ac7476baf39b928";
    sha256 = "0qbvy3sc7miwf2bicxd1lqfc1adrykpajpjcfpmmsjdwqvhkq8sy";
  };
  racketThinBuildInputs = [ self."alexis-collections" self."base" self."curly-fn" self."lens" self."scribble-lib" self."at-exp-lib" self."cover" self."cover-coveralls" self."doc-coverage" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexis-collections" = self.lib.mkRacketDerivation rec {
  pname = "alexis-collections";
  src = fetchgit {
    name = "alexis-collections";
    url = "git://github.com/lexi-lambda/racket-alexis-collections.git";
    rev = "997c8642d9b2adb28728d609202618bc8ffbd750";
    sha256 = "0ix48pb0i72a5p1cniyp7g7h8v8c1zhpdm9lrrcjwwvvsb8rz2l3";
  };
  racketThinBuildInputs = [ self."alexis-util" self."base" self."collections" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexis-multicast" = self.lib.mkRacketDerivation rec {
  pname = "alexis-multicast";
  src = self.lib.extractPath {
    path = "alexis-multicast";
    src = fetchgit {
    name = "alexis-multicast";
    url = "git://github.com/lexi-lambda/racket-alexis.git";
    rev = "0268afb688231e0d6d76ded3291538dd5d3db37c";
    sha256 = "076bpg6fxd914wjnb6dym729gcmysxxhrriy3fw6z54n55hmc3nl";
  };
  };
  racketThinBuildInputs = [ self."base" self."alexis-util" self."rackunit-lib" self."cover" self."cover-coveralls" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexis-pvector" = self.lib.mkRacketDerivation rec {
  pname = "alexis-pvector";
  src = fetchgit {
    name = "alexis-pvector";
    url = "git://github.com/lexi-lambda/racket-alexis-pvector.git";
    rev = "f03b60714a0fd35ca61dd41307701074a2253d87";
    sha256 = "1ghjx2pwzhbnh24xdcazipr7bh731z730iar21vz6lvqy30m1mnk";
  };
  racketThinBuildInputs = [ self."alexis-collections" self."base" self."pvector" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexis-util" = self.lib.mkRacketDerivation rec {
  pname = "alexis-util";
  src = self.lib.extractPath {
    path = "alexis-util";
    src = fetchgit {
    name = "alexis-util";
    url = "git://github.com/lexi-lambda/racket-alexis.git";
    rev = "0268afb688231e0d6d76ded3291538dd5d3db37c";
    sha256 = "076bpg6fxd914wjnb6dym729gcmysxxhrriy3fw6z54n55hmc3nl";
  };
  };
  racketThinBuildInputs = [ self."base" self."match-plus" self."scribble-lib" self."static-rename" self."threading" self."typed-racket-lib" self."rackunit-lib" self."at-exp-lib" self."racket-doc" self."typed-racket-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexknauth-music" = self.lib.mkRacketDerivation rec {
  pname = "alexknauth-music";
  src = fetchgit {
    name = "alexknauth-music";
    url = "git://github.com/AlexKnauth/music.git";
    rev = "b4489c27d7c0f7116d769344c787fa76b479e5fa";
    sha256 = "0sr10h22byw6544k668p85xas4fk1mjvgf25jyw30q0ys29gspwx";
  };
  racketThinBuildInputs = [ self."base" self."agile" self."collections-lib" self."htdp-lib" self."math-lib" self."graph" self."txexpr" self."reprovide-lang" self."rsound" self."unstable-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "alexknauth-my-object" = self.lib.mkRacketDerivation rec {
  pname = "alexknauth-my-object";
  src = fetchgit {
    name = "alexknauth-my-object";
    url = "git://github.com/AlexKnauth/my-object.git";
    rev = "5a6ee970bad2ab86d2d69e1dbf2f7bb158e88963";
    sha256 = "0i64kqs6s49z61wlkcz1zxznvzmlibjvy6pylnbyz3dwshnfcrpy";
  };
  racketThinBuildInputs = [ self."base" self."lens" self."hash-lambda" self."kw-utils" self."unstable-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."heresy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "algebraic" = self.lib.mkRacketDerivation rec {
  pname = "algebraic";
  src = fetchgit {
    name = "algebraic";
    url = "git://github.com/dedbox/racket-algebraic.git";
    rev = "706b2d01ab735a01e372c33da49995339194e024";
    sha256 = "09in2fskky4lfww95s3s765kkdw0c9b2p80xzz09pjpi4bliyvky";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."pict-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."texmath" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "algebraic-app" = self.lib.mkRacketDerivation rec {
  pname = "algebraic-app";
  src = fetchgit {
    name = "algebraic-app";
    url = "git://github.com/dedbox/racket-algebraic-app.git";
    rev = "60355507f5dc713df68ab962d17b64015be9b06e";
    sha256 = "0d1ybsj249bsvfa6lvjpbadrfhnc6ga1qb5inw2151fsjp1jz279";
  };
  racketThinBuildInputs = [ self."algebraic" self."base" self."k-infix" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "algol60" = self.lib.mkRacketDerivation rec {
  pname = "algol60";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/algol60.zip";
    sha1 = "cbf59ecaa2bd1f0a7ca82b5fa22772ceffe36e3f";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."parser-tools-lib" self."string-constants-lib" self."at-exp-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."scribble-lib" self."drracket-tool-lib" self."drracket-plugin-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "algorithms" = self.lib.mkRacketDerivation rec {
  pname = "algorithms";
  src = fetchgit {
    name = "algorithms";
    url = "git://github.com/codereport/racket-algorithms.git";
    rev = "f73428847d6fa3faf9260b3821224e2afcf820b2";
    sha256 = "1a1xzw34hy0g1dmsk4zp68p7hmr7ysl370p8482qhwa00cwnqb8s";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "anaphoric" = self.lib.mkRacketDerivation rec {
  pname = "anaphoric";
  src = fetchgit {
    name = "anaphoric";
    url = "git://github.com/jsmaniac/anaphoric.git";
    rev = "2c21a489cb522549869e2c482299123544e47c78";
    sha256 = "118pw3fjjh0b0blw8h2jnn9zzmy844dsjz2mmbk4vyy2ihnwldxz";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "anarki" = self.lib.mkRacketDerivation rec {
  pname = "anarki";
  src = fetchgit {
    name = "anarki";
    url = "git://github.com/arclanguage/anarki.git";
    rev = "0913288ec1477f2598e8095a2b5e9b14eb97dc4e";
    sha256 = "0xa4np2pb7xm63g5bpg4qdicixazbyr6wnqz6d3pssy5j2xc682n";
  };
  racketThinBuildInputs = [ self."base" self."sha" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "animated-canvas" = self.lib.mkRacketDerivation rec {
  pname = "animated-canvas";
  src = fetchgit {
    name = "animated-canvas";
    url = "git://github.com/spdegabrielle/animated-canvas.git";
    rev = "30df78c403f3ff90c6395cd8eb782140a4f1cc77";
    sha256 = "1ykalnp4vg4i85nancjd7g1spi57cfmywbdpc5hfbfi2vjnrvgic";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ansi" = self.lib.mkRacketDerivation rec {
  pname = "ansi";
  src = fetchgit {
    name = "ansi";
    url = "git://github.com/tonyg/racket-ansi.git";
    rev = "1e64b8efc0d731f06a672620b0fccfda01c03735";
    sha256 = "0d4904kpasw2sd2gq989y3hadjkrhgbmlfdrd48pl2fnz1315b7x";
  };
  racketThinBuildInputs = [ self."base" self."dynext-lib" self."make" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ansi-color" = self.lib.mkRacketDerivation rec {
  pname = "ansi-color";
  src = fetchgit {
    name = "ansi-color";
    url = "git://github.com/renatoathaydes/ansi-color.git";
    rev = "20363d90fcef9219580ec0d6a78eea834df39d21";
    sha256 = "1wmzzb3ffffhgy35wj0zy6x1z4crsw2m1rc1hmxwlyc3lvhcbm1x";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aoc-racket" = self.lib.mkRacketDerivation rec {
  pname = "aoc-racket";
  src = fetchgit {
    name = "aoc-racket";
    url = "git://github.com/mbutterick/aoc-racket.git";
    rev = "3dbf1361033d69f896650e8d53e2badb33a05a10";
    sha256 = "05fzzprvh8263vj1yr70kmr755zrry8x7q9hz4ghzh8khs8py315";
  };
  racketThinBuildInputs = [ self."graph" self."base" self."scribble-lib" self."sugar" self."rackunit-lib" self."math-lib" self."beautiful-racket-lib" self."gregor" self."debug" self."draw-lib" self."gui-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."rackunit-doc" self."at-exp-lib" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aosd" = self.lib.mkRacketDerivation rec {
  pname = "aosd";
  src = fetchgit {
    name = "aosd";
    url = "git://github.com/takikawa/racket-aosd.git";
    rev = "7ab51262a256a324b062d7b407cb5341d1f41f69";
    sha256 = "0wnickk2axhprdjx1dihvg226f4l6pmky8pafgsc55gkj8pj1jx6";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."x11" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "apply" = self.lib.mkRacketDerivation rec {
  pname = "apply";
  src = self.lib.extractPath {
    path = "apply";
    src = fetchgit {
    name = "apply";
    url = "git://github.com/zaoqil/apply.git";
    rev = "1d7d138179cd02e2b10eab29748d08b76d91c69d";
    sha256 = "05yvlajmg50493lp8vv53vgd607f5206ybjmc3v334jaarsz8r7f";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "appveyor-racket" = self.lib.mkRacketDerivation rec {
  pname = "appveyor-racket";
  src = fetchgit {
    name = "appveyor-racket";
    url = "git://github.com/liberalartist/appveyor-racket.git";
    rev = "21f21d99160a0edefd7ceeb001210c88a8af1099";
    sha256 = "1qzhjr195z3idgf8a8r62dmwhs766i74lcm7bhhli8lgihdil7wp";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "apse" = self.lib.mkRacketDerivation rec {
  pname = "apse";
  src = fetchgit {
    name = "apse";
    url = "git://github.com/jeapostrophe/apse.git";
    rev = "b02dfe2de3f7ae1a1edf931c9555408e6354a5bc";
    sha256 = "1pvxvzsy99gn74qa8qm5cbr21xxqy2nbvd1bw4v0arlwps01bgg6";
  };
  racketThinBuildInputs = [ self."base" self."lux" self."mode-lambda" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "argo" = self.lib.mkRacketDerivation rec {
  pname = "argo";
  src = fetchgit {
    name = "argo";
    url = "git://github.com/jessealama/argo.git";
    rev = "aa2e14608dffa648719b3fa6725862a88e1b2477";
    sha256 = "03cy91xfn8fh8ajmn0dgkrisah022p2kmhv6hlnqnhi2np80vfaf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."http" self."sugar" self."beautiful-racket-lib" self."web-server-lib" self."json-pointer" self."uri-template" self."ejs" self."brag" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."beautiful-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "arguments" = self.lib.mkRacketDerivation rec {
  pname = "arguments";
  src = self.lib.extractPath {
    path = "arguments";
    src = fetchgit {
    name = "arguments";
    url = "git://github.com/jackfirth/racket-mock.git";
    rev = "1a27bb7a1444effc034bf8b2df4ba1845f51478f";
    sha256 = "1d7y7f08ys0lg3m89zy66whkzpd7vdn4xhkp5nv99vg0pdl2zilm";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "arroy" = self.lib.mkRacketDerivation rec {
  pname = "arroy";
  src = fetchgit {
    name = "arroy";
    url = "git://github.com/jeapostrophe/arroy.git";
    rev = "487b8cbacc5f1f9a4600f55b8c0f7f148f7c2747";
    sha256 = "0spb6km181d9lkn0qzv1iwwahwg9wgdwx73ims32makq8mb4f1y6";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asi64" = self.lib.mkRacketDerivation rec {
  pname = "asi64";
  src = fetchgit {
    name = "asi64";
    url = "git://github.com/pezipink/asi64.git";
    rev = "81e61a25a6f35e137df6326353b9c54f50f2d829";
    sha256 = "0y0yii2yj6bsm44sd10i2d3yb6mxdbc9bja55zra76ibwfpzxvd5";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asm" = self.lib.mkRacketDerivation rec {
  pname = "asm";
  src = fetchgit {
    name = "asm";
    url = "git://github.com/lwhjp/racket-asm.git";
    rev = "d5194143d9ba47d00ca8e366a71bc39b897eb318";
    sha256 = "0aj95a31c4cmns38ryp0g1mm186sp2vm8lyc04j2l3cy8mxxs0qp";
  };
  racketThinBuildInputs = [ self."base" self."binutils" self."data-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asn1" = self.lib.mkRacketDerivation rec {
  pname = "asn1";
  src = self.lib.extractPath {
    path = "asn1";
    src = fetchgit {
    name = "asn1";
    url = "git://github.com/rmculpepper/asn1.git";
    rev = "2921d5953deeea33413cfd358bb4768cc775277b";
    sha256 = "0z4dy45qdygnyjlfhhs21s52jcjihg7hjx72lga20m9i59jl4a69";
  };
  };
  racketThinBuildInputs = [ self."base" self."asn1-lib" self."asn1-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asn1-doc" = self.lib.mkRacketDerivation rec {
  pname = "asn1-doc";
  src = self.lib.extractPath {
    path = "asn1-doc";
    src = fetchgit {
    name = "asn1-doc";
    url = "git://github.com/rmculpepper/asn1.git";
    rev = "2921d5953deeea33413cfd358bb4768cc775277b";
    sha256 = "0z4dy45qdygnyjlfhhs21s52jcjihg7hjx72lga20m9i59jl4a69";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."asn1-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asn1-lib" = self.lib.mkRacketDerivation rec {
  pname = "asn1-lib";
  src = self.lib.extractPath {
    path = "asn1-lib";
    src = fetchgit {
    name = "asn1-lib";
    url = "git://github.com/rmculpepper/asn1.git";
    rev = "2921d5953deeea33413cfd358bb4768cc775277b";
    sha256 = "0z4dy45qdygnyjlfhhs21s52jcjihg7hjx72lga20m9i59jl4a69";
  };
  };
  racketThinBuildInputs = [ self."base" self."binaryio-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asn1-test" = self.lib.mkRacketDerivation rec {
  pname = "asn1-test";
  src = self.lib.extractPath {
    path = "asn1-test";
    src = fetchgit {
    name = "asn1-test";
    url = "git://github.com/rmculpepper/asn1.git";
    rev = "2921d5953deeea33413cfd358bb4768cc775277b";
    sha256 = "0z4dy45qdygnyjlfhhs21s52jcjihg7hjx72lga20m9i59jl4a69";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."asn1-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "asyncunit" = self.lib.mkRacketDerivation rec {
  pname = "asyncunit";
  src = fetchgit {
    name = "asyncunit";
    url = "git://github.com/schuster/asyncunit.git";
    rev = "ef9e5c45e83a6f44539d45c8ac52935a463a9659";
    sha256 = "1s038g6sjy4f9abk5pafczbjrh2bhhp32xhiz197va705p8hcivr";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "at-exp-lib" = self.lib.mkRacketDerivation rec {
  pname = "at-exp-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/at-exp-lib.zip";
    sha1 = "c747d0ed8ab45e4979098a81bef9ba990462e7d6";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "atomichron" = self.lib.mkRacketDerivation rec {
  pname = "atomichron";
  src = fetchgit {
    name = "atomichron";
    url = "git://github.com/jackfirth/atomichron.git";
    rev = "397838da6336a006efd1e17a6985461d79d1fe91";
    sha256 = "129kdn6a7k1q5y0mm5hkkg8rsw86qg9fac4bmc1bvwmnszjgyq8j";
  };
  racketThinBuildInputs = [ self."base" self."rebellion" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "auto-syntax-e" = self.lib.mkRacketDerivation rec {
  pname = "auto-syntax-e";
  src = fetchgit {
    name = "auto-syntax-e";
    url = "git://github.com/jsmaniac/auto-syntax-e.git";
    rev = "2b64df7050b6b0c4f6568e765434bb2786453a5b";
    sha256 = "0jdl4npp95y39nxvaqkr840lisyc6sl6sn5xi82zqp83099h0fnq";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "automata" = self.lib.mkRacketDerivation rec {
  pname = "automata";
  src = self.lib.extractPath {
    path = "automata";
    src = fetchgit {
    name = "automata";
    url = "git://github.com/jeapostrophe/automata.git";
    rev = "a82d4d3c94f55c6560ec14f76300811658ed05a6";
    sha256 = "06gwyy6zyz3p3rcq6vl893pg0ksz2pyn6a1la67d5an3hmkikj04";
  };
  };
  racketThinBuildInputs = [ self."automata-lib" self."automata-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "automata-doc" = self.lib.mkRacketDerivation rec {
  pname = "automata-doc";
  src = self.lib.extractPath {
    path = "automata-doc";
    src = fetchgit {
    name = "automata-doc";
    url = "git://github.com/jeapostrophe/automata.git";
    rev = "a82d4d3c94f55c6560ec14f76300811658ed05a6";
    sha256 = "06gwyy6zyz3p3rcq6vl893pg0ksz2pyn6a1la67d5an3hmkikj04";
  };
  };
  racketThinBuildInputs = [ self."base" self."automata-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "automata-lib" = self.lib.mkRacketDerivation rec {
  pname = "automata-lib";
  src = self.lib.extractPath {
    path = "automata-lib";
    src = fetchgit {
    name = "automata-lib";
    url = "git://github.com/jeapostrophe/automata.git";
    rev = "a82d4d3c94f55c6560ec14f76300811658ed05a6";
    sha256 = "06gwyy6zyz3p3rcq6vl893pg0ksz2pyn6a1la67d5an3hmkikj04";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "automata-test" = self.lib.mkRacketDerivation rec {
  pname = "automata-test";
  src = self.lib.extractPath {
    path = "automata-test";
    src = fetchgit {
    name = "automata-test";
    url = "git://github.com/jeapostrophe/automata.git";
    rev = "a82d4d3c94f55c6560ec14f76300811658ed05a6";
    sha256 = "06gwyy6zyz3p3rcq6vl893pg0ksz2pyn6a1la67d5an3hmkikj04";
  };
  };
  racketThinBuildInputs = [ self."base" self."automata-lib" self."eli-tester" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "auxiliary-macro-context" = self.lib.mkRacketDerivation rec {
  pname = "auxiliary-macro-context";
  src = fetchgit {
    name = "auxiliary-macro-context";
    url = "git://github.com/tonyg/racket-auxiliary-macro-context.git";
    rev = "52d3df7f937700bcea5b4d200903cfb6575afdc6";
    sha256 = "0rdw9dxyywa3n32ljchjj12p163n951ck698ph0vwjx0aam4mxyn";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "avl" = self.lib.mkRacketDerivation rec {
  pname = "avl";
  src = fetchgit {
    name = "avl";
    url = "git://github.com/mordae/racket-avl.git";
    rev = "e981880a7d4c202368cdd74c94cf11cbac42a29e";
    sha256 = "1pmpv988kgki68vr3q6ylpb8495vswmq3n6g8jymyjx2bhj99p39";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aws" = self.lib.mkRacketDerivation rec {
  pname = "aws";
  src = fetchgit {
    name = "aws";
    url = "git://github.com/greghendershott/aws.git";
    rev = "b1dcb619b6768c96d1276778439f379660ee5404";
    sha256 = "0sd64257gzdvc7nyy1ki775shswwnb8qyjda72qg22527scc5ijq";
  };
  racketThinBuildInputs = [ self."base" self."http" self."sha" self."rackunit-lib" self."at-exp-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aws-cloudformation-deploy" = self.lib.mkRacketDerivation rec {
  pname = "aws-cloudformation-deploy";
  src = fetchgit {
    name = "aws-cloudformation-deploy";
    url = "git://github.com/cjdev/aws-cloudformation-deploy.git";
    rev = "00d1107fe8c08712d9011c9bb46d3f4ab9d0cc70";
    sha256 = "0w30j4zz3lzb8r4qh45371z3p5rm7gfqpnk8n8h2cd434vvzq4yx";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aws-cloudformation-template" = self.lib.mkRacketDerivation rec {
  pname = "aws-cloudformation-template";
  src = self.lib.extractPath {
    path = "aws-cloudformation-template";
    src = fetchgit {
    name = "aws-cloudformation-template";
    url = "git://github.com/lexi-lambda/aws-cloudformation-template.git";
    rev = "00f52274a5bfc03f23c9dd511db0c87e35cf80e5";
    sha256 = "0ndzv098xfx10a9dc1mp10kqwlhfngxj2i44nyrs0y4myz14wh0v";
  };
  };
  racketThinBuildInputs = [ self."aws-cloudformation-template-doc" self."aws-cloudformation-template-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aws-cloudformation-template-doc" = self.lib.mkRacketDerivation rec {
  pname = "aws-cloudformation-template-doc";
  src = self.lib.extractPath {
    path = "aws-cloudformation-template-doc";
    src = fetchgit {
    name = "aws-cloudformation-template-doc";
    url = "git://github.com/lexi-lambda/aws-cloudformation-template.git";
    rev = "00f52274a5bfc03f23c9dd511db0c87e35cf80e5";
    sha256 = "0ndzv098xfx10a9dc1mp10kqwlhfngxj2i44nyrs0y4myz14wh0v";
  };
  };
  racketThinBuildInputs = [ self."aws-cloudformation-template-lib" self."base" self."racket-doc" self."scribble-lib" self."threading-lib" self."turnstile" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "aws-cloudformation-template-lib" = self.lib.mkRacketDerivation rec {
  pname = "aws-cloudformation-template-lib";
  src = self.lib.extractPath {
    path = "aws-cloudformation-template-lib";
    src = fetchgit {
    name = "aws-cloudformation-template-lib";
    url = "git://github.com/lexi-lambda/aws-cloudformation-template.git";
    rev = "00f52274a5bfc03f23c9dd511db0c87e35cf80e5";
    sha256 = "0ndzv098xfx10a9dc1mp10kqwlhfngxj2i44nyrs0y4myz14wh0v";
  };
  };
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."syntax-classes-lib" self."threading-lib" self."turnstile" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "axe" = self.lib.mkRacketDerivation rec {
  pname = "axe";
  src = fetchgit {
    name = "axe";
    url = "git://github.com/lotabout/axe.git";
    rev = "234c2d1f6849f3719c3fc3c2354a4d257e53943b";
    sha256 = "1d5d37x79igyl3kcg1z88ip2mlpq4llmwwawg7qfa4zcr7h2gdrp";
  };
  racketThinBuildInputs = [ self."base" self."collections" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-code-examples" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "backport-template-pr1514" = self.lib.mkRacketDerivation rec {
  pname = "backport-template-pr1514";
  src = fetchgit {
    name = "backport-template-pr1514";
    url = "git://github.com/jsmaniac/backport-template-pr1514.git";
    rev = "d7d74f5af236a26b38b94f59623b8b6e02b9e5ba";
    sha256 = "0k9qrwx5ny398bszwvf1d7xgp1nxilwszmzaz0akawkv3852caxm";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."version-case" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "base" = self.lib.mkRacketDerivation rec {
  pname = "base";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/base.zip";
    sha1 = "0cfbc7c7b3530f5e83a6e882386e6a53062dd5c4";
  };
  racketThinBuildInputs = [ self."racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "base32" = self.lib.mkRacketDerivation rec {
  pname = "base32";
  src = fetchgit {
    name = "base32";
    url = "git://github.com/afldcr/racket-base32.git";
    rev = "ea130f84dbac547d40f5bd27d1be53df811b4fd7";
    sha256 = "1n6m4nwj03640bg7rc0dyps54p82k1arnjxfxbgsqjkshsqprnki";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "basedir" = self.lib.mkRacketDerivation rec {
  pname = "basedir";
  src = fetchgit {
    name = "basedir";
    url = "git://github.com/willghatch/racket-basedir.git";
    rev = "722c06fb943f0a6e263cad057cedd80ea50e888d";
    sha256 = "0dkpdyvi9p2vxpna6jf88942875hm2di3z0h707hninbx7aymy97";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bazaar" = self.lib.mkRacketDerivation rec {
  pname = "bazaar";
  src = fetchgit {
    name = "bazaar";
    url = "git://github.com/Metaxal/bazaar.git";
    rev = "2f53cceb44f78543360a643df064a1720bff9e29";
    sha256 = "1vhcv3kacvq4iy6mx0n7cs2q8mm23rmqdjx98qd842vycm188bv7";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."draw-lib" self."gui-lib" self."images" self."math-lib" self."net-lib" self."plot-gui-lib" self."plot-lib" self."racket-index" self."rackunit-lib" self."scribble-lib" self."slideshow-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bcrypt" = self.lib.mkRacketDerivation rec {
  pname = "bcrypt";
  src = fetchgit {
    name = "bcrypt";
    url = "git://github.com/samth/bcrypt.rkt.git";
    rev = "9bd08aad72920735df5ba3f9571b08301acd3401";
    sha256 = "1vly1f3anp8x0n3c3ybmiw0fj24998rnnbil2b11d4vs88lpb5s7";
  };
  racketThinBuildInputs = [ self."base" self."dynext-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "beautiful-racket" = self.lib.mkRacketDerivation rec {
  pname = "beautiful-racket";
  src = self.lib.extractPath {
    path = "beautiful-racket";
    src = fetchgit {
    name = "beautiful-racket";
    url = "git://github.com/mbutterick/beautiful-racket.git";
    rev = "db99679d5e79a15ddf355d90664ba45499790a9a";
    sha256 = "07xmj0hir8a7ip71340797lfc25lm2wliiyz132cpdvyv6cwn64j";
  };
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."beautiful-racket-demo" self."gui-doc" self."gui-lib" self."at-exp-lib" self."br-parser-tools-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "beautiful-racket-demo" = self.lib.mkRacketDerivation rec {
  pname = "beautiful-racket-demo";
  src = self.lib.extractPath {
    path = "beautiful-racket-demo";
    src = fetchgit {
    name = "beautiful-racket-demo";
    url = "git://github.com/mbutterick/beautiful-racket.git";
    rev = "db99679d5e79a15ddf355d90664ba45499790a9a";
    sha256 = "07xmj0hir8a7ip71340797lfc25lm2wliiyz132cpdvyv6cwn64j";
  };
  };
  racketThinBuildInputs = [ self."base" self."sugar" self."beautiful-racket-lib" self."rackunit-lib" self."brag" self."srfi-lib" self."draw-lib" self."syntax-color-lib" self."gui-lib" self."math-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "beautiful-racket-lib" = self.lib.mkRacketDerivation rec {
  pname = "beautiful-racket-lib";
  src = self.lib.extractPath {
    path = "beautiful-racket-lib";
    src = fetchgit {
    name = "beautiful-racket-lib";
    url = "git://github.com/mbutterick/beautiful-racket.git";
    rev = "db99679d5e79a15ddf355d90664ba45499790a9a";
    sha256 = "07xmj0hir8a7ip71340797lfc25lm2wliiyz132cpdvyv6cwn64j";
  };
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-macro" self."at-exp-lib" self."sugar" self."debug" self."rackunit-lib" self."gui-lib" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "beautiful-racket-macro" = self.lib.mkRacketDerivation rec {
  pname = "beautiful-racket-macro";
  src = self.lib.extractPath {
    path = "beautiful-racket-macro";
    src = fetchgit {
    name = "beautiful-racket-macro";
    url = "git://github.com/mbutterick/beautiful-racket.git";
    rev = "db99679d5e79a15ddf355d90664ba45499790a9a";
    sha256 = "07xmj0hir8a7ip71340797lfc25lm2wliiyz132cpdvyv6cwn64j";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "behavior" = self.lib.mkRacketDerivation rec {
  pname = "behavior";
  src = fetchgit {
    name = "behavior";
    url = "git://github.com/johnstonskj/behavior.git";
    rev = "72103db75c07d52d9027b34f0960532e235f9c10";
    sha256 = "0mljbcsj8qa4vc2cr7i3274v7g7jihjadwfkld5h8fgs1h8hrgfs";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-index" self."scribble-lib" self."scribble-math" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "benchmark" = self.lib.mkRacketDerivation rec {
  pname = "benchmark";
  src = fetchgit {
    name = "benchmark";
    url = "git://github.com/stamourv/racket-benchmark";
    rev = "de7e84539de23834508dba42e07859cf13bde20c";
    sha256 = "19czqq5qykl8p3z3f5q8k6qsmwd6sj1yys8j5prlxqyvd0wgmcxb";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."plot-gui-lib" self."plot-lib" self."typed-racket-lib" self."plot-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "benchmark-ips" = self.lib.mkRacketDerivation rec {
  pname = "benchmark-ips";
  src = fetchgit {
    name = "benchmark-ips";
    url = "git://github.com/zenspider/benchmark-ips-racket.git";
    rev = "264e756c409f52020462901ee1f5059c9fe674eb";
    sha256 = "0vkqwh1sn6n0n1zir8aaskxf2400lspl7ly5140j1f1h01wcswqj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bencode" = self.lib.mkRacketDerivation rec {
  pname = "bencode";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/bencode.zip";
    sha1 = "676a8979ef85eefd1373c2afb91649a22ae98c93";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bencode-codec" = self.lib.mkRacketDerivation rec {
  pname = "bencode-codec";
  src = fetchgit {
    name = "bencode-codec";
    url = "git://github.com/tonyg/racket-bencode.git";
    rev = "cf4161c67e0a6f3f25fa162b9f61a3460b4ce445";
    sha256 = "0279xv1w5sg148jrpy6a6p4gk0b044k1sjl4iwhcwc85gprc6942";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "berkeley" = self.lib.mkRacketDerivation rec {
  pname = "berkeley";
  src = fetchurl {
    url = "http://inst.eecs.berkeley.edu/~cs61as/library/berkeley.zip";
    sha1 = "8c9c56d99d9f157a84d94d887143340246da9d73";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binary-class" = self.lib.mkRacketDerivation rec {
  pname = "binary-class";
  src = fetchgit {
    name = "binary-class";
    url = "git://github.com/Kalimehtar/binary-class.git";
    rev = "69705ed306be38c9e4dd67d9075ec160ecdb82a4";
    sha256 = "0h3xa9i973ka4ilkr82ifa9dgmsrkv747bk74x56gl6km3r7lmyk";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binary-class-dbf" = self.lib.mkRacketDerivation rec {
  pname = "binary-class-dbf";
  src = fetchgit {
    name = "binary-class-dbf";
    url = "git://github.com/Kalimehtar/binary-class-dbf.git";
    rev = "751ed1b7e44f6894d7bdc468727bfc854677338b";
    sha256 = "1v2jwzcivxx8kq2s6m87i01grjr1s1lf9rw1zj3ys0ff5fdr1v4r";
  };
  racketThinBuildInputs = [ self."binary-class" self."base" self."fast-convert" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binary-class-exif" = self.lib.mkRacketDerivation rec {
  pname = "binary-class-exif";
  src = fetchgit {
    name = "binary-class-exif";
    url = "git://github.com/Kalimehtar/binary-class-exif.git";
    rev = "8d475c4dd72de90decedeb3fc0acd53d9cf6f60d";
    sha256 = "13r62npg6j82zzdc6zs45a9hfmnirnjkmv26qvqfzjkij17gzcfp";
  };
  racketThinBuildInputs = [ self."binary-class" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binary-class-mp3" = self.lib.mkRacketDerivation rec {
  pname = "binary-class-mp3";
  src = fetchgit {
    name = "binary-class-mp3";
    url = "git://github.com/Kalimehtar/binary-class-mp3.git";
    rev = "bc10152d1bc6cd1ed7be7bec0e8d3f1ae0bf7977";
    sha256 = "17k16f9q6dyaw7lfp9mkasj0gc6mrblp8z0464im4jlhn102b3pa";
  };
  racketThinBuildInputs = [ self."binary-class" self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binary-class-riff" = self.lib.mkRacketDerivation rec {
  pname = "binary-class-riff";
  src = fetchgit {
    name = "binary-class-riff";
    url = "git://github.com/lwhjp/binary-class-riff.git";
    rev = "2062f82382eed570b502a935f740621d3971d527";
    sha256 = "1h7rcijd5vx1h3l4f9wcjszgh3c147nh3mr77cx5va9bkpxqg6dm";
  };
  racketThinBuildInputs = [ self."base" self."binary-class" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binaryio" = self.lib.mkRacketDerivation rec {
  pname = "binaryio";
  src = self.lib.extractPath {
    path = "binaryio";
    src = fetchgit {
    name = "binaryio";
    url = "git://github.com/rmculpepper/binaryio.git";
    rev = "85e2ae6ce58f85c2adabb7220495441f807fc847";
    sha256 = "1s74qixjq995hhwdlcnkc5zzw605q5jfyby4gb0j483y47ami6n7";
  };
  };
  racketThinBuildInputs = [ self."base" self."binaryio-lib" self."rackunit-lib" self."math-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binaryio-lib" = self.lib.mkRacketDerivation rec {
  pname = "binaryio-lib";
  src = self.lib.extractPath {
    path = "binaryio-lib";
    src = fetchgit {
    name = "binaryio-lib";
    url = "git://github.com/rmculpepper/binaryio.git";
    rev = "85e2ae6ce58f85c2adabb7220495441f807fc847";
    sha256 = "1s74qixjq995hhwdlcnkc5zzw605q5jfyby4gb0j483y47ami6n7";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "binutils" = self.lib.mkRacketDerivation rec {
  pname = "binutils";
  src = fetchgit {
    name = "binutils";
    url = "git://github.com/lwhjp/racket-binutils.git";
    rev = "0023f772c58fb89d8a29f7880f8d2e855faa58a0";
    sha256 = "0wsi5lsysmyryavj6a3wbklk1vh03x2lpsx7rfadvbkm858yxm2v";
  };
  racketThinBuildInputs = [ self."base" self."binary-class" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bitsyntax" = self.lib.mkRacketDerivation rec {
  pname = "bitsyntax";
  src = fetchgit {
    name = "bitsyntax";
    url = "git://github.com/tonyg/racket-bitsyntax.git";
    rev = "e28efc87dac903ede1fbd87c87cff9cc5550db1a";
    sha256 = "1pipm0hyk4a0vpplxvpafhgfwn72ynmhs0i14mccigpqfc1y7yjf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bloggy" = self.lib.mkRacketDerivation rec {
  pname = "bloggy";
  src = fetchgit {
    name = "bloggy";
    url = "git://github.com/jeapostrophe/bloggy.git";
    rev = "d189325911f28fdfd9b8d7ae64225838d6400596";
    sha256 = "1gy54c7nay7byird24fv4g6r1p70rsfrb11cklyc4c2n49yj5ssw";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bluetooth-socket" = self.lib.mkRacketDerivation rec {
  pname = "bluetooth-socket";
  src = fetchgit {
    name = "bluetooth-socket";
    url = "https://gitlab.com/RayRacine/bluetooth-socket.git";
    rev = "bd48368028d2b0e69ba96399d2771d163d40cf46";
    sha256 = "1d5k17w1nmpg7sanrwcji4sk3z2ncwgchdnyp4kd1pkz7qcs0dgr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bnf" = self.lib.mkRacketDerivation rec {
  pname = "bnf";
  src = self.lib.extractPath {
    path = "bnf";
    src = fetchgit {
    name = "bnf";
    url = "git://github.com/philnguyen/bnf.git";
    rev = "8b1e995e41cdaf87163c9697b35eea81111d9c35";
    sha256 = "0rb3clvz1n740n4a12sf8s12jn93qfrwbsxwd1jn976dd93jz3dy";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."typed-struct-props" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bookcover" = self.lib.mkRacketDerivation rec {
  pname = "bookcover";
  src = fetchgit {
    name = "bookcover";
    url = "git://github.com/otherjoel/bookcover.git";
    rev = "824cdc44d35cc2c418074e4eaf12bbb0e516342f";
    sha256 = "1gl7p9gw4fq540fpmirn4lkvmiybdl27bj9s6br44j6m9ivcrip0";
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."draw-lib" self."pict-lib" self."draw-doc" self."pict-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "br-parser-tools" = self.lib.mkRacketDerivation rec {
  pname = "br-parser-tools";
  src = self.lib.extractPath {
    path = "br-parser-tools";
    src = fetchgit {
    name = "br-parser-tools";
    url = "git://github.com/mbutterick/br-parser-tools.git";
    rev = "87cc90839d383d523a405eb0ae2b449a2e2a0ff4";
    sha256 = "17scpxwzj8h6am1aqa144897cqhdzmwai1lvgn0vph0j28vc7y1n";
  };
  };
  racketThinBuildInputs = [ self."br-parser-tools-lib" self."br-parser-tools-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "br-parser-tools-doc" = self.lib.mkRacketDerivation rec {
  pname = "br-parser-tools-doc";
  src = self.lib.extractPath {
    path = "br-parser-tools-doc";
    src = fetchgit {
    name = "br-parser-tools-doc";
    url = "git://github.com/mbutterick/br-parser-tools.git";
    rev = "87cc90839d383d523a405eb0ae2b449a2e2a0ff4";
    sha256 = "17scpxwzj8h6am1aqa144897cqhdzmwai1lvgn0vph0j28vc7y1n";
  };
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."racket-doc" self."syntax-color-doc" self."br-parser-tools-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "br-parser-tools-lib" = self.lib.mkRacketDerivation rec {
  pname = "br-parser-tools-lib";
  src = self.lib.extractPath {
    path = "br-parser-tools-lib";
    src = fetchgit {
    name = "br-parser-tools-lib";
    url = "git://github.com/mbutterick/br-parser-tools.git";
    rev = "87cc90839d383d523a405eb0ae2b449a2e2a0ff4";
    sha256 = "17scpxwzj8h6am1aqa144897cqhdzmwai1lvgn0vph0j28vc7y1n";
  };
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "brag" = self.lib.mkRacketDerivation rec {
  pname = "brag";
  src = self.lib.extractPath {
    path = "brag";
    src = fetchgit {
    name = "brag";
    url = "git://github.com/mbutterick/brag.git";
    rev = "8814be702bb219a9a90eba5688b8b989033b66c7";
    sha256 = "02fwjyry7s2bwcv981x58hs5dp8g15j9hparv6hcxbx7li7yp83l";
  };
  };
  racketThinBuildInputs = [ self."base" self."brag-lib" self."at-exp-lib" self."br-parser-tools-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "brag-lib" = self.lib.mkRacketDerivation rec {
  pname = "brag-lib";
  src = self.lib.extractPath {
    path = "brag-lib";
    src = fetchgit {
    name = "brag-lib";
    url = "git://github.com/mbutterick/brag.git";
    rev = "8814be702bb219a9a90eba5688b8b989033b66c7";
    sha256 = "02fwjyry7s2bwcv981x58hs5dp8g15j9hparv6hcxbx7li7yp83l";
  };
  };
  racketThinBuildInputs = [ self."base" self."br-parser-tools-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "brazilian-law" = self.lib.mkRacketDerivation rec {
  pname = "brazilian-law";
  src = fetchgit {
    name = "brazilian-law";
    url = "git://github.com/OAB-exams/brazilian-law-parser.git";
    rev = "912433fd9755e309d7e681fa2c74cff5e692a6d8";
    sha256 = "0xc0rbkc9xg1fvhsrgr9gsz1w0izmklj4jz4s0w4mvv0xwzwzzc1";
  };
  racketThinBuildInputs = [ self."base" self."megaparsack" self."txexpr" self."curly-fn-lib" self."functional-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "brush" = self.lib.mkRacketDerivation rec {
  pname = "brush";
  src = fetchgit {
    name = "brush";
    url = "git://github.com/david-christiansen/brush.git";
    rev = "91b83cda313f77f2068f0c02753c55c2563680d5";
    sha256 = "17rg5z7vmpqmdprssrif96wm5k775s1fmafchnbysc38xr15j4cw";
  };
  racketThinBuildInputs = [ self."base" self."scribble" self."at-exp-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bs" = self.lib.mkRacketDerivation rec {
  pname = "bs";
  src = fetchgit {
    name = "bs";
    url = "git://github.com/oldsin/bs.git";
    rev = "0a88ed7217076a6286fdaef0183bea596149991b";
    sha256 = "079alzyql1k0jq9n2wianc76xqgyl8v8n61z8x4sjn4vxqrgl4as";
  };
  racketThinBuildInputs = [ self."base" self."brag" self."crypto-lib" self."parser-tools-lib" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "buid" = self.lib.mkRacketDerivation rec {
  pname = "buid";
  src = fetchgit {
    name = "buid";
    url = "git://github.com/Bogdanp/racket-buid.git";
    rev = "5806054cbea5e69fae66a0b6d622752ace690afd";
    sha256 = "10a3s75yvwq4p34dxj96by39qv3x7nqsb3dvdzps8qvzn2p5xpzd";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackcheck" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bv" = self.lib.mkRacketDerivation rec {
  pname = "bv";
  src = fetchgit {
    name = "bv";
    url = "git://github.com/pmatos/racket-bv.git";
    rev = "dedd9a5aa1922ec546c6a8270fa00e0cbb229f1c";
    sha256 = "0ixd10vhfwy0bjclf9vfiisak6n64l3nnmvskm39fwq7zhha87r3";
  };
  racketThinBuildInputs = [ self."base" self."mischief" self."math-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."quickcheck" self."rosette" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bystroTeX" = self.lib.mkRacketDerivation rec {
  pname = "bystroTeX";
  src = self.lib.extractPath {
    path = "bystroTeX";
    src = fetchgit {
    name = "bystroTeX";
    url = "git://github.com/amkhlv/amkhlv.git";
    rev = "1ef0ff936e49a36467422755788ecd682708cfa0";
    sha256 = "0ywvkkv48mm84wkszij286g8yhs0l01pi0rmcf8b3jjvjmc3cqja";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."db-lib" self."scheme-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bzip2" = self.lib.mkRacketDerivation rec {
  pname = "bzip2";
  src = fetchgit {
    name = "bzip2";
    url = "git://github.com/97jaz/racket-bzip2.git";
    rev = "7ceadc95e6221fd9a46f2b009cfc302117fe7f02";
    sha256 = "15xm4ws53702gbpsrb6133l9991hzpzycwgzksbm4197kbfngjhs";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "c" = self.lib.mkRacketDerivation rec {
  pname = "c";
  src = fetchgit {
    name = "c";
    url = "git://github.com/jeapostrophe/c.git";
    rev = "c2efa315c13e420e6cf77ba8d5ce1f7eb9dbdc2c";
    sha256 = "1ff014lnj5bx060fz6dbfwpyvjlvla3frmiachf356qj4blnhjq9";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."parser-tools-doc" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "c-defs" = self.lib.mkRacketDerivation rec {
  pname = "c-defs";
  src = fetchgit {
    name = "c-defs";
    url = "git://github.com/belph/c-defs.git";
    rev = "d5b7ba438ccdead8213e96051a205b696e4a8a93";
    sha256 = "0r1wfmjrrvby25pqgbn69npq32axqp2j6vn1gk84js1dis543fs5";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "c-utils" = self.lib.mkRacketDerivation rec {
  pname = "c-utils";
  src = fetchgit {
    name = "c-utils";
    url = "git://github.com/samth/c.rkt.git";
    rev = "a7087828d18fee7268c51104783279d285076560";
    sha256 = "065kcddybw85gjmaxyknfks5jaj6mikzxz5nn2ry8z6ibkjypi7m";
  };
  racketThinBuildInputs = [ self."abnf" self."base" self."parser-tools-lib" self."at-exp-lib" self."parser-tools-doc" self."planet-doc" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."scribble-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cKanren" = self.lib.mkRacketDerivation rec {
  pname = "cKanren";
  src = fetchgit {
    name = "cKanren";
    url = "git://github.com/calvis/cKanren.git";
    rev = "8714bdd442ca03dbf5b1d6250904cbc5fd275e68";
    sha256 = "0fm3gmg6wfnqdkcrc7yl9y1bz6db4m6m2zlj9miyby3mcndkhw5k";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "calendar" = self.lib.mkRacketDerivation rec {
  pname = "calendar";
  src = fetchgit {
    name = "calendar";
    url = "git://github.com/LeifAndersen/racket-calendar.git";
    rev = "1c38c3804b8f4d87d5036d67018839276bdf6875";
    sha256 = "1rlk9h5ws2dnm1lmz6dnxf60a35rdba29f3pk4k61zi8gs5s6hfg";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gregor-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "canonicalize-path" = self.lib.mkRacketDerivation rec {
  pname = "canonicalize-path";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/canonicalize-path.zip";
    sha1 = "87391a22ed5dfa80e5cac219a241a162e85fa3a1";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."mcfly" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "carl-lib" = self.lib.mkRacketDerivation rec {
  pname = "carl-lib";
  src = fetchgit {
    name = "carl-lib";
    url = "git://github.com/mkyl/carl-lib.git";
    rev = "c2d02a2a370ed70b9b2ae029f586eb9cc390718a";
    sha256 = "1kqmp4k3zafn0s8z99d31k9hsj73gs3wqslck5a8lr0vifpbzi4z";
  };
  racketThinBuildInputs = [ self."base" self."brag-lib" self."db" self."graph" self."math-lib" self."rackunit-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "casemate" = self.lib.mkRacketDerivation rec {
  pname = "casemate";
  src = fetchgit {
    name = "casemate";
    url = "git://github.com/jozip/casemate.git";
    rev = "8a2a3801300b538f3152cd3829c2a19c996fd57e";
    sha256 = "09q2vzai2cazy47gflc1q8ddc5n9bfgi7w2s4gb8lkzsaf2mzjk3";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cc4101-handin" = self.lib.mkRacketDerivation rec {
  pname = "cc4101-handin";
  src = fetchgit {
    name = "cc4101-handin";
    url = "git://github.com/pleiad/cc4101-handin-client.git";
    rev = "4baadf45f07a1d79d1d2213356e1e60a72092242";
    sha256 = "0j6jmy8bhxyx8xv0ampd2ckic7h908i9h44y64i164fi3m9xxbra";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."net-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ccnum" = self.lib.mkRacketDerivation rec {
  pname = "ccnum";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/ccnum.zip";
    sha1 = "6a9e1802743086bb53c086d9e2b093849cd11e3b";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cext-lib" = self.lib.mkRacketDerivation rec {
  pname = "cext-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/cext-lib.zip";
    sha1 = "2fe6c2581d49ea9b16b6f3ab07d1b657510bb665";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."dynext-lib" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chain-module-begin" = self.lib.mkRacketDerivation rec {
  pname = "chain-module-begin";
  src = fetchgit {
    name = "chain-module-begin";
    url = "git://github.com/jsmaniac/chain-module-begin.git";
    rev = "b297d9453a600da9a8ebac4425fdf137aca45d04";
    sha256 = "14x2n6zcj3phfmnq0k3a1ghaa7jcz7fxarsxm78ppjy45bwchwz6";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."debug-scopes" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "charterm" = self.lib.mkRacketDerivation rec {
  pname = "charterm";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/charterm.zip";
    sha1 = "71dc10e9e39babd5afb6af62098d6b54ae7bfe8e";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "check-sexp-equal" = self.lib.mkRacketDerivation rec {
  pname = "check-sexp-equal";
  src = fetchgit {
    name = "check-sexp-equal";
    url = "git://github.com/zenspider/check-sexp-equal.git";
    rev = "59d1d837e8d7d6d0d4a8d4dc23497a9589f234fc";
    sha256 = "1iiy0vr4irhiqqipff3f71vp1s9ljjbzcb8bxqf6kydj6qzc9jl0";
  };
  racketThinBuildInputs = [ self."sexp-diff" self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chess" = self.lib.mkRacketDerivation rec {
  pname = "chess";
  src = fetchgit {
    name = "chess";
    url = "git://github.com/jackfirth/chess.git";
    rev = "accceb86b391769ebf1f83fe7f2deda09b34ab82";
    sha256 = "1zpq2sqxsqwwyvzngyhx7jfwigvhw12mcn6ihs58y48df69y3ljx";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."rebellion" self."reprovide-lang" self."pict-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chez-runner" = self.lib.mkRacketDerivation rec {
  pname = "chez-runner";
  src = fetchgit {
    name = "chez-runner";
    url = "git://github.com/Syntacticlosure/chez-runner.git";
    rev = "a999587b41ff7c1da3a3fe2bb95fd8483ef77905";
    sha256 = "0l1l3f2sq70fis8r27saip7kiyll9i5dx9gk02vyag1i7ai792nf";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."drracket" self."rackunit-lib" self."scribble-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chido-parse" = self.lib.mkRacketDerivation rec {
  pname = "chido-parse";
  src = fetchgit {
    name = "chido-parse";
    url = "git://github.com/willghatch/racket-chido-parse.git";
    rev = "d04934b0589a8255b6d5b9faea04346244d98303";
    sha256 = "1i4jrmid08wg3sl65am57pysc269kda9g31wxv11wbb804i20dm1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."data-lib" self."kw-make-struct" self."quickcheck" self."web-server-lib" self."at-exp-lib" self."linea" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chief" = self.lib.mkRacketDerivation rec {
  pname = "chief";
  src = self.lib.extractPath {
    path = "chief";
    src = fetchgit {
    name = "chief";
    url = "git://github.com/Bogdanp/racket-chief.git";
    rev = "b790e057c60b3a30ff8232cd0684aab2ebb167f1";
    sha256 = "1p34pdl8zgz420p38kkr28kd5cdq723y7fx6lhda0lg195xk3b4z";
  };
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chk" = self.lib.mkRacketDerivation rec {
  pname = "chk";
  src = self.lib.extractPath {
    path = "chk";
    src = fetchgit {
    name = "chk";
    url = "git://github.com/jeapostrophe/chk.git";
    rev = "be74d7bad039141c1c142c0590dead552445b260";
    sha256 = "052cf4w7xgq2y4kbmvb5pqn3pifmjhw1qg0451x9sp02ac66ghd0";
  };
  };
  racketThinBuildInputs = [ self."chk-lib" self."chk-doc" self."chk-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chk-doc" = self.lib.mkRacketDerivation rec {
  pname = "chk-doc";
  src = self.lib.extractPath {
    path = "chk-doc";
    src = fetchgit {
    name = "chk-doc";
    url = "git://github.com/jeapostrophe/chk.git";
    rev = "be74d7bad039141c1c142c0590dead552445b260";
    sha256 = "052cf4w7xgq2y4kbmvb5pqn3pifmjhw1qg0451x9sp02ac66ghd0";
  };
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."chk-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chk-lib" = self.lib.mkRacketDerivation rec {
  pname = "chk-lib";
  src = self.lib.extractPath {
    path = "chk-lib";
    src = fetchgit {
    name = "chk-lib";
    url = "git://github.com/jeapostrophe/chk.git";
    rev = "be74d7bad039141c1c142c0590dead552445b260";
    sha256 = "052cf4w7xgq2y4kbmvb5pqn3pifmjhw1qg0451x9sp02ac66ghd0";
  };
  };
  racketThinBuildInputs = [ self."testing-util-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "chk-test" = self.lib.mkRacketDerivation rec {
  pname = "chk-test";
  src = self.lib.extractPath {
    path = "chk-test";
    src = fetchgit {
    name = "chk-test";
    url = "git://github.com/jeapostrophe/chk.git";
    rev = "be74d7bad039141c1c142c0590dead552445b260";
    sha256 = "052cf4w7xgq2y4kbmvb5pqn3pifmjhw1qg0451x9sp02ac66ghd0";
  };
  };
  racketThinBuildInputs = [ self."chk-lib" self."testing-util-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "choose-lang" = self.lib.mkRacketDerivation rec {
  pname = "choose-lang";
  src = fetchgit {
    name = "choose-lang";
    url = "https://gitlab.com/bengreenman/choose-lang.git";
    rev = "582a224f42e5a0ac82a99e13a6ce3d7298f14fcf";
    sha256 = "08yyw3vgp4qj5807cy932wa98s9sqlvzfdc6yd188bx7i112wfaj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-abbrevs" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "choose-out" = self.lib.mkRacketDerivation rec {
  pname = "choose-out";
  src = fetchgit {
    name = "choose-out";
    url = "https://gitlab.com/bengreenman/choose-out.git";
    rev = "1f95bbe28c3ae1f4bc1e2556a2e363ae344c1bfd";
    sha256 = "1n4q7a2w7m1qrb72k65b00z2v25iybp7l2vwfwvbqs1q62qp9bp0";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-abbrevs" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "circuit-playground" = self.lib.mkRacketDerivation rec {
  pname = "circuit-playground";
  src = fetchgit {
    name = "circuit-playground";
    url = "git://github.com/thoughtstem/circuit-playground.git";
    rev = "755086bdbbc57ab4df7de2315c5f56d85024506c";
    sha256 = "0wymqyqp77j59fs8vbsmi30a0dh55azxm195jncy5ijvwsysp2jy";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "clang" = self.lib.mkRacketDerivation rec {
  pname = "clang";
  src = fetchgit {
    name = "clang";
    url = "git://github.com/wargrey/clang.git";
    rev = "9c8b0c9e4583b181bfc68d7dcf9e31cddaa4ad37";
    sha256 = "0m8lgckkis4pb1p7hg1yz5ncygjmzyc8r3si47iq6fs244h5nmbs";
  };
  racketThinBuildInputs = [ self."base" self."graphics" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "class-iop" = self.lib.mkRacketDerivation rec {
  pname = "class-iop";
  src = self.lib.extractPath {
    path = "class-iop";
    src = fetchgit {
    name = "class-iop";
    url = "git://github.com/racket/class-iop.git";
    rev = "f5105b5cfdc7b72d9c7ffc053f884fc66677f861";
    sha256 = "0idzwgrcl300lkkl67d0mswl0k2k9hx6phvwnwkik6f6v15znjfs";
  };
  };
  racketThinBuildInputs = [ self."class-iop-lib" self."class-iop-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "class-iop-doc" = self.lib.mkRacketDerivation rec {
  pname = "class-iop-doc";
  src = self.lib.extractPath {
    path = "class-iop-doc";
    src = fetchgit {
    name = "class-iop-doc";
    url = "git://github.com/racket/class-iop.git";
    rev = "f5105b5cfdc7b72d9c7ffc053f884fc66677f861";
    sha256 = "0idzwgrcl300lkkl67d0mswl0k2k9hx6phvwnwkik6f6v15znjfs";
  };
  };
  racketThinBuildInputs = [ self."base" self."class-iop-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "class-iop-lib" = self.lib.mkRacketDerivation rec {
  pname = "class-iop-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/class-iop-lib.zip";
    sha1 = "f5738336340c77b5799359ce9c005ab49d37716d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "classicthesis-scribble" = self.lib.mkRacketDerivation rec {
  pname = "classicthesis-scribble";
  src = fetchgit {
    name = "classicthesis-scribble";
    url = "git://github.com/stamourv/classicthesis-scribble.git";
    rev = "e6c3f2be24654cbf0b17d9027737c2d3eb1cddd1";
    sha256 = "1hm35h8c71bi3b5n9ysry11n9adz3zzdrb4iqhvivf8hwi8ncxcf";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cldr-bcp47" = self.lib.mkRacketDerivation rec {
  pname = "cldr-bcp47";
  src = fetchgit {
    name = "cldr-bcp47";
    url = "git://github.com/97jaz/cldr-bcp47.git";
    rev = "823fc1a530f1a0ec4de59f5454c1a17f20c5a5d6";
    sha256 = "0l06a7nv7hylwsjw9i5yzjyswggvq7g64g09wdbw7m8hhbinm3k1";
  };
  racketThinBuildInputs = [ self."base" self."cldr-core" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cldr-core" = self.lib.mkRacketDerivation rec {
  pname = "cldr-core";
  src = fetchgit {
    name = "cldr-core";
    url = "git://github.com/97jaz/cldr-core.git";
    rev = "8a4d6de47ea572bfcee8d4df498be893906f52de";
    sha256 = "12ybng7sp57mhw96z3vpsx0zk3dfq87khxadwxril4pmj5jg98pn";
  };
  racketThinBuildInputs = [ self."base" self."memoize" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cldr-dates-modern" = self.lib.mkRacketDerivation rec {
  pname = "cldr-dates-modern";
  src = fetchgit {
    name = "cldr-dates-modern";
    url = "git://github.com/97jaz/cldr-dates-modern.git";
    rev = "c36282917247f6a069e553535f4619007cd7b6e5";
    sha256 = "1cvb57xj9g75kqb3laz35jknj79894yji9axwzyp7qrrpfwzc83g";
  };
  racketThinBuildInputs = [ self."base" self."cldr-core" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cldr-localenames-modern" = self.lib.mkRacketDerivation rec {
  pname = "cldr-localenames-modern";
  src = fetchgit {
    name = "cldr-localenames-modern";
    url = "git://github.com/97jaz/cldr-localenames-modern.git";
    rev = "f9f3e8d9245764a309542816acf40fe147b473a3";
    sha256 = "1a54rja5lhz9x9mz55pvicz2ppidvapqf34qf2i9p9959fg5z7bx";
  };
  racketThinBuildInputs = [ self."base" self."cldr-core" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cldr-numbers-modern" = self.lib.mkRacketDerivation rec {
  pname = "cldr-numbers-modern";
  src = fetchgit {
    name = "cldr-numbers-modern";
    url = "git://github.com/97jaz/cldr-numbers-modern.git";
    rev = "625428099b3f8cd264955a283dddc176a6080ba1";
    sha256 = "159ckjnyx6f7dajg6w5q4cd5gzfrdsbp9xhc6spgrj8jidvvadj4";
  };
  racketThinBuildInputs = [ self."base" self."cldr-core" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "clicker-assets" = self.lib.mkRacketDerivation rec {
  pname = "clicker-assets";
  src = fetchgit {
    name = "clicker-assets";
    url = "git://github.com/thoughtstem/clicker-assets.git";
    rev = "a377ae67172c3174a094c4794ea98c9f50b1dedd";
    sha256 = "0nw9pcwq3kd3i692drvnij9akb8ik1axmry92qvzb3a4y69mvssk";
  };
  racketThinBuildInputs = [ self."base" self."define-assets-from" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "client-cookies" = self.lib.mkRacketDerivation rec {
  pname = "client-cookies";
  src = fetchgit {
    name = "client-cookies";
    url = "git://github.com/Kalimehtar/client-cookies.git";
    rev = "ea699f80c4865c71971a73b4cfc444969a633c6c";
    sha256 = "0nd16r7cia0hz8qyhc7rfdw6gfl2yam716y2mqq9id1p9b1sj8bl";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cmx" = self.lib.mkRacketDerivation rec {
  pname = "cmx";
  src = fetchgit {
    name = "cmx";
    url = "git://github.com/dedbox/racket-cmx.git";
    rev = "3591f092f7aac01e5c529d5b82421e321cdda8cb";
    sha256 = "0x8jplsw9vav3xav2xn8bsfgxqjnppqpla47xcg43rbcy365w77b";
  };
  racketThinBuildInputs = [ self."base" self."event-lang" self."draw-lib" self."pict-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "collections" = self.lib.mkRacketDerivation rec {
  pname = "collections";
  src = self.lib.extractPath {
    path = "collections";
    src = fetchgit {
    name = "collections";
    url = "git://github.com/lexi-lambda/racket-collections.git";
    rev = "5b3ec9b3ea3ca493f3fcda4994b81bc804f29870";
    sha256 = "0vh781q0iw0wv1a741qp7s9havc030p5wahz6vcdhfn9azv00znp";
  };
  };
  racketThinBuildInputs = [ self."collections-lib" self."collections-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "collections-doc" = self.lib.mkRacketDerivation rec {
  pname = "collections-doc";
  src = self.lib.extractPath {
    path = "collections-doc";
    src = fetchgit {
    name = "collections-doc";
    url = "git://github.com/lexi-lambda/racket-collections.git";
    rev = "5b3ec9b3ea3ca493f3fcda4994b81bc804f29870";
    sha256 = "0vh781q0iw0wv1a741qp7s9havc030p5wahz6vcdhfn9azv00znp";
  };
  };
  racketThinBuildInputs = [ self."collections-doc+functional-doc" self."base" self."collections-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [ "functional-doc" "collections-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "collections-doc+functional-doc" = self.lib.mkRacketDerivation rec {
  pname = "collections-doc+functional-doc";

  extraSrcs = [ self."functional-doc".src self."collections-doc".src ];
  racketThinBuildInputs = [ self."base" self."collections-lib" self."functional-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "functional-doc" "collections-doc" ];
  };
  "collections-lens" = self.lib.mkRacketDerivation rec {
  pname = "collections-lens";
  src = fetchgit {
    name = "collections-lens";
    url = "git://github.com/lexi-lambda/collections-lens.git";
    rev = "73556daf4885558ea6a66a5def8ad668c0fcf4c3";
    sha256 = "1d5f4swvfzp7h8dxka8i4q77mq8c7xj6laxmchc45f88a4vald8a";
  };
  racketThinBuildInputs = [ self."base" self."collections" self."curly-fn" self."lens-common" self."scribble-lib" self."at-exp-lib" self."racket-doc" self."lens-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "collections-lib" = self.lib.mkRacketDerivation rec {
  pname = "collections-lib";
  src = self.lib.extractPath {
    path = "collections-lib";
    src = fetchgit {
    name = "collections-lib";
    url = "git://github.com/lexi-lambda/racket-collections.git";
    rev = "5b3ec9b3ea3ca493f3fcda4994b81bc804f29870";
    sha256 = "0vh781q0iw0wv1a741qp7s9havc030p5wahz6vcdhfn9azv00znp";
  };
  };
  racketThinBuildInputs = [ self."collections-lib+functional-lib" self."base" self."curly-fn-lib" self."match-plus" self."static-rename" self."unstable-list-lib" ];
  circularBuildInputs = [ "collections-lib" "functional-lib" ];
  reverseCircularBuildInputs = [  ];
  };
  "collections-lib+functional-lib" = self.lib.mkRacketDerivation rec {
  pname = "collections-lib+functional-lib";

  extraSrcs = [ self."collections-lib".src self."functional-lib".src ];
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."match-plus" self."static-rename" self."unstable-list-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "collections-lib" "functional-lib" ];
  };
  "collections-test" = self.lib.mkRacketDerivation rec {
  pname = "collections-test";
  src = self.lib.extractPath {
    path = "collections-test";
    src = fetchgit {
    name = "collections-test";
    url = "git://github.com/lexi-lambda/racket-collections.git";
    rev = "5b3ec9b3ea3ca493f3fcda4994b81bc804f29870";
    sha256 = "0vh781q0iw0wv1a741qp7s9havc030p5wahz6vcdhfn9azv00znp";
  };
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."match-plus" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colon-kw" = self.lib.mkRacketDerivation rec {
  pname = "colon-kw";
  src = fetchgit {
    name = "colon-kw";
    url = "git://github.com/AlexKnauth/colon-kw.git";
    rev = "a338070d902753978a5a297c737845c013231ea7";
    sha256 = "098na9q9ql9a2qn7vwzri7rj641p8hkc44v71q6z4sf5flwbz8ws";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colon-match" = self.lib.mkRacketDerivation rec {
  pname = "colon-match";
  src = fetchgit {
    name = "colon-match";
    url = "git://github.com/AlexKnauth/colon-match.git";
    rev = "7cccb5fdb4e5301ec2b2d38c553ad3050f7d542d";
    sha256 = "1y4axbcwf7lal2b2s6zdp6qal9nlqnm463rzyzjfasiywxkim6zh";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "color-flood" = self.lib.mkRacketDerivation rec {
  pname = "color-flood";
  src = fetchgit {
    name = "color-flood";
    url = "git://github.com/Metaxal/color-flood.git";
    rev = "86f82e312587e982695ef5dd687e247f97bae7f5";
    sha256 = "14pd2scajv035bmv4q184ja8y12qi096hvjgd44phiimnwgv3816";
  };
  racketThinBuildInputs = [ self."base" self."bazaar" self."gui-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "color-strings" = self.lib.mkRacketDerivation rec {
  pname = "color-strings";
  src = fetchgit {
    name = "color-strings";
    url = "git://github.com/thoughtstem/color-strings.git";
    rev = "6f6f5594f46ebcdc96ab9c82edc4e5a90d6f0896";
    sha256 = "1299ksy18pzjkr56grsl0b3mm16dydfzq5vcsx02i6b607fpkslq";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colorize" = self.lib.mkRacketDerivation rec {
  pname = "colorize";
  src = fetchgit {
    name = "colorize";
    url = "git://github.com/yanyingwang/colorize.git";
    rev = "157878ae018b5b6aebeb5e5e51d73ca38af4ad08";
    sha256 = "0kjlnzggh4rimx1ih0anbk09ybhasj2np2rbfpq6bsgv7x65m9rj";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colormaps" = self.lib.mkRacketDerivation rec {
  pname = "colormaps";
  src = fetchgit {
    name = "colormaps";
    url = "git://github.com/alex-hhh/colormaps.git";
    rev = "833d2d9e27ddeab664bf9936c0cd271f39dca0c0";
    sha256 = "06qgs1sxxz5hqb8vkm8r7g00wjpvmw8hf041w4hihcy3splw1vsq";
  };
  racketThinBuildInputs = [ self."base" self."plot-lib" self."pict-lib" self."draw-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."pict-doc" self."plot-doc" self."plot-gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colors" = self.lib.mkRacketDerivation rec {
  pname = "colors";
  src = fetchgit {
    name = "colors";
    url = "git://github.com/florence/colors.git";
    rev = "103aa2aa71310b0c7a83b33714593f01ce24beab";
    sha256 = "0l1l51z2x875rjk0l8lpikildr9sijzc63mgrxnfzm2x3zvbp9m2";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."racket-doc" self."scribble-lib" self."debug" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "colors-as-strings" = self.lib.mkRacketDerivation rec {
  pname = "colors-as-strings";
  src = fetchgit {
    name = "colors-as-strings";
    url = "git://github.com/thoughtstem/colors-as-strings.git";
    rev = "6f6f5594f46ebcdc96ab9c82edc4e5a90d6f0896";
    sha256 = "1299ksy18pzjkr56grsl0b3mm16dydfzq5vcsx02i6b607fpkslq";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "com-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "com-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/com-win32-i386.zip";
    sha1 = "901d03171bc5939b0b4784522175310082ecfaea";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "com-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "com-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/com-win32-x86_64.zip";
    sha1 = "dd80d27dd2ad90ca46c35763eee0d3c935ad2a11";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "combinator-parser" = self.lib.mkRacketDerivation rec {
  pname = "combinator-parser";
  src = fetchgit {
    name = "combinator-parser";
    url = "git://github.com/takikawa/combinator-parser.git";
    rev = "e64f938862f47f0e8bab8d6f406a8fa6a203e435";
    sha256 = "15iksz88qy40k9zgmv43fjf69lad15vzrrabv6z8daa8anipqky9";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."compatibility-lib" self."scribble-lib" self."parser-tools-doc" self."racket-doc" self."at-exp-lib" self."lazy" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "comm-panel" = self.lib.mkRacketDerivation rec {
  pname = "comm-panel";
  src = fetchgit {
    name = "comm-panel";
    url = "git://github.com/thoughtstem/comm-panel.git";
    rev = "44225da9b3cd1f883beef9c03f20431f80239530";
    sha256 = "0xbs4vkkyqbbbkz2ilfn275ijsjfp1rg4j2xpzw7px8k9bdi8zvl";
  };
  racketThinBuildInputs = [ self."happy-names" self."aws" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "command-line-ext" = self.lib.mkRacketDerivation rec {
  pname = "command-line-ext";
  src = fetchgit {
    name = "command-line-ext";
    url = "git://github.com/jackfirth/command-line-ext.git";
    rev = "02525e983bd1b233eab641b942338991f406ae6f";
    sha256 = "0cd784alf8k58mfsixyy6p7mjxlx3di75m9asnhxr7zckisd67jv";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."fancy-app" self."generic-syntax-expanders" self."reprovide-lang" self."lens" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "command-tree" = self.lib.mkRacketDerivation rec {
  pname = "command-tree";
  src = fetchgit {
    name = "command-tree";
    url = "git://github.com/euhmeuh/command-tree.git";
    rev = "3a5dd35d43f3be52fb9743361adcb53eabcb8a3a";
    sha256 = "0jcjmaykww0v0f8790yrgkbyfyfjbd5mayz1xj8bi859ck6b7akx";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compact-annotations" = self.lib.mkRacketDerivation rec {
  pname = "compact-annotations";
  src = fetchgit {
    name = "compact-annotations";
    url = "git://github.com/jackfirth/compact-annotations.git";
    rev = "dcd5f87dec21f40904e92eefb747472151bd3ace";
    sha256 = "1vkf6fxf01rdiwh61hghblkryyd0yvqafxpxvcf4xpwknjbbmlma";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."cover" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility" = self.lib.mkRacketDerivation rec {
  pname = "compatibility";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compatibility.zip";
    sha1 = "2c5ff0e46b7525503a9c038f33dcb30198549264";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." = self.lib.mkRacketDerivation rec {
  pname = "compatibility+compatibility-doc+data-doc+db-doc+distributed-p...";

  extraSrcs = [ self."racket-doc".src self."readline".src self."draw".src self."syntax-color".src self."parser-tools-doc".src self."compatibility".src self."pict".src self."future-visualizer".src self."distributed-places-doc".src self."distributed-places".src self."trace".src self."planet-doc".src self."quickscript".src self."drracket-tool-doc".src self."drracket".src self."gui".src self."xrepl".src self."typed-racket-doc".src self."slideshow-doc".src self."pict-doc".src self."draw-doc".src self."syntax-color-doc".src self."string-constants-doc".src self."readline-doc".src self."macro-debugger".src self."errortrace-doc".src self."profile-doc".src self."xrepl-doc".src self."gui-doc".src self."scribble-doc".src self."net-cookies-doc".src self."net-doc".src self."compatibility-doc".src self."rackunit-doc".src self."web-server-doc".src self."db-doc".src self."mzscheme-doc".src self."r5rs-doc".src self."r6rs-doc".src self."srfi-doc".src self."plot-doc".src self."math-doc".src self."data-doc".src ];
  racketThinBuildInputs = [ self."2d-lib" self."at-exp-lib" self."base" self."cext-lib" self."class-iop-lib" self."compatibility-lib" self."compiler-lib" self."data-enumerate-lib" self."data-lib" self."db-lib" self."distributed-places-lib" self."draw-lib" self."drracket-plugin-lib" self."drracket-tool-lib" self."errortrace-lib" self."gui-lib" self."gui-pkg-manager-lib" self."htdp-lib" self."html-lib" self."icons" self."images-gui-lib" self."images-lib" self."macro-debugger-text-lib" self."math-lib" self."net-cookies-lib" self."net-lib" self."option-contract-lib" self."parser-tools-lib" self."pconvert-lib" self."pict-lib" self."pict-snip-lib" self."planet-lib" self."plot-compat" self."plot-gui-lib" self."plot-lib" self."profile-lib" self."r5rs-lib" self."r6rs-lib" self."racket-index" self."rackunit-gui" self."rackunit-lib" self."readline-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."scribble-text-lib" self."serialize-cstruct-lib" self."slideshow-lib" self."snip-lib" self."srfi-lib" self."srfi-lite-lib" self."string-constants-lib" self."syntax-color-lib" self."tex-table" self."typed-racket-compatibility" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."wxme-lib" self."xrepl-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  };
  "compatibility-doc" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compatibility-doc.zip";
    sha1 = "269792ae5b6c306130a87a059c306d523ceb86ae";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."compatibility-lib" self."pconvert-lib" self."sandbox-lib" self."compiler-lib" self."gui-lib" self."scheme-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility-lib" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compatibility-lib.zip";
    sha1 = "33b6e0f086e59efc39fbc99c0c1f9ea1190ee58e";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."net-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility-test" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compatibility-test.zip";
    sha1 = "d15af027ac251dd17c7731e0c8f5a18392c65aea";
  };
  racketThinBuildInputs = [ self."base" self."racket-test" self."compatibility-lib" self."drracket-tool-lib" self."rackunit-lib" self."pconvert-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler" = self.lib.mkRacketDerivation rec {
  pname = "compiler";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compiler.zip";
    sha1 = "17549a4f7a3fafb7a9d0ba1a5aa982ec102896b5";
  };
  racketThinBuildInputs = [ self."compiler-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler-goodies" = self.lib.mkRacketDerivation rec {
  pname = "compiler-goodies";
  src = fetchgit {
    name = "compiler-goodies";
    url = "git://github.com/LeifAndersen/racket-compiler-goodies.git";
    rev = "4378d1039bd958ee4bfddafc5ec4dd8ef15bd5bb";
    sha256 = "04c2fw9y5qr7i93srd7i1kpr4znpyam08z4cb6vv0nagxa50m1c9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."compiler-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler-lib" = self.lib.mkRacketDerivation rec {
  pname = "compiler-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compiler-lib.zip";
    sha1 = "c75b6c3f6c9ddf160321663dc8c2780c9f40e365";
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."rackunit-lib" self."zo-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler-test" = self.lib.mkRacketDerivation rec {
  pname = "compiler-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/compiler-test.zip";
    sha1 = "2e2d350b4a6bc9c4d36c9cb236088d9008231a4e";
  };
  racketThinBuildInputs = [ self."base" self."icons" self."compiler-lib" self."eli-tester" self."rackunit-lib" self."net-lib" self."scheme-lib" self."compatibility-lib" self."gui-lib" self."htdp-lib" self."plai-lib" self."rackunit-lib" self."dynext-lib" self."mzscheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "component" = self.lib.mkRacketDerivation rec {
  pname = "component";
  src = self.lib.extractPath {
    path = "component";
    src = fetchgit {
    name = "component";
    url = "git://github.com/Bogdanp/racket-component.git";
    rev = "1069c8dad15ceef6bfb4457996095c9702ac7c38";
    sha256 = "14ddbcbnnqcdn3v57pzh4zfhk0jr62y39y1rkyj25mms2qr09h1d";
  };
  };
  racketThinBuildInputs = [ self."component-doc" self."component-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "component-doc" = self.lib.mkRacketDerivation rec {
  pname = "component-doc";
  src = self.lib.extractPath {
    path = "component-doc";
    src = fetchgit {
    name = "component-doc";
    url = "git://github.com/Bogdanp/racket-component.git";
    rev = "1069c8dad15ceef6bfb4457996095c9702ac7c38";
    sha256 = "14ddbcbnnqcdn3v57pzh4zfhk0jr62y39y1rkyj25mms2qr09h1d";
  };
  };
  racketThinBuildInputs = [ self."base" self."component-lib" self."db-doc" self."db-lib" self."scribble-lib" self."racket-doc" self."rackunit-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "component-lib" = self.lib.mkRacketDerivation rec {
  pname = "component-lib";
  src = self.lib.extractPath {
    path = "component-lib";
    src = fetchgit {
    name = "component-lib";
    url = "git://github.com/Bogdanp/racket-component.git";
    rev = "1069c8dad15ceef6bfb4457996095c9702ac7c38";
    sha256 = "14ddbcbnnqcdn3v57pzh4zfhk0jr62y39y1rkyj25mms2qr09h1d";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "component-test" = self.lib.mkRacketDerivation rec {
  pname = "component-test";
  src = self.lib.extractPath {
    path = "component-test";
    src = fetchgit {
    name = "component-test";
    url = "git://github.com/Bogdanp/racket-component.git";
    rev = "1069c8dad15ceef6bfb4457996095c9702ac7c38";
    sha256 = "14ddbcbnnqcdn3v57pzh4zfhk0jr62y39y1rkyj25mms2qr09h1d";
  };
  };
  racketThinBuildInputs = [ self."base" self."component-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compose-app" = self.lib.mkRacketDerivation rec {
  pname = "compose-app";
  src = fetchgit {
    name = "compose-app";
    url = "git://github.com/jackfirth/compose-app.git";
    rev = "b1ca7838740c3cc84e392ea17f9e57f0595c111f";
    sha256 = "1pp5mg0fk3c2k358cr5isvd7mdd73plk2pg12vrnp9wlsmnnabm0";
  };
  racketThinBuildInputs = [ self."base" self."fancy-app" self."racket-doc" self."scribble-lib" self."scribble-text-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cond-contract" = self.lib.mkRacketDerivation rec {
  pname = "cond-contract";
  src = fetchgit {
    name = "cond-contract";
    url = "git://github.com/pmatos/cond-contract.git";
    rev = "8f8f1605d91a15fe653c407076a6fc64f69cbebe";
    sha256 = "03zc82cfk0l7276di5v9y17ls401dmip5phl1cd9c8a7m3gs12pc";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cond-strict" = self.lib.mkRacketDerivation rec {
  pname = "cond-strict";
  src = fetchgit {
    name = "cond-strict";
    url = "git://github.com/AlexKnauth/cond-strict.git";
    rev = "449212681ea5675beda19bf8242411f6073882ee";
    sha256 = "1g258l7ryly6yn00p4ml780mncgrhkx917vra6bly7vhajymar8l";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "continued-fractions" = self.lib.mkRacketDerivation rec {
  pname = "continued-fractions";
  src = fetchgit {
    name = "continued-fractions";
    url = "https://derend@bitbucket.org/derend/continued-fractions.git";
    rev = "1b64abbd6adcaf781c7873a8489bbeff87cbaa56";
    sha256 = "03rd2jj45kpsadcgrxyjx3b3np34s035lb417cnjm3i5df5hkc8m";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "contract-profile" = self.lib.mkRacketDerivation rec {
  pname = "contract-profile";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/contract-profile.zip";
    sha1 = "14a220d541a3d2e62e103068b72157f3c25ebbf6";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."profile-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "contract-repl" = self.lib.mkRacketDerivation rec {
  pname = "contract-repl";
  src = fetchgit {
    name = "contract-repl";
    url = "git://github.com/takikawa/contract-repl.git";
    rev = "5eadd5d87b04178d5574804313238934f3544692";
    sha256 = "0bg2agcs6wymlm4z824q8lz2405a2a5rxy4hrsp58v1v5v6mz2c9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "control" = self.lib.mkRacketDerivation rec {
  pname = "control";
  src = fetchgit {
    name = "control";
    url = "git://github.com/soegaard/control.git";
    rev = "51bc2319c07a06b1275a231c8ccfc433a8f34258";
    sha256 = "007lmdzzi630l7z166hrc9pna5rd64bycswz9q5q6m3v8hf585a1";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "country" = self.lib.mkRacketDerivation rec {
  pname = "country";
  src = self.lib.extractPath {
    path = "country";
    src = fetchgit {
    name = "country";
    url = "git://github.com/Bogdanp/racket-country.git";
    rev = "df92b3158b5735d86879c489d3e7b78664030281";
    sha256 = "1zac0xhhplfxyh600nij252mak3hx6kxjgbr5dh169p10g8dmaxn";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover" = self.lib.mkRacketDerivation rec {
  pname = "cover";
  src = self.lib.extractPath {
    path = "cover";
    src = fetchgit {
    name = "cover";
    url = "git://github.com/florence/cover.git";
    rev = "ad50ffa8f6246053bec24b39b9cae7fad1534373";
    sha256 = "1dhfk8fgwi4by3rjzkdf20b6kvy839k2xakcklsc25a1x8vn0l8w";
  };
  };
  racketThinBuildInputs = [ self."cover-lib" self."cover-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-benchmarks" = self.lib.mkRacketDerivation rec {
  pname = "cover-benchmarks";
  src = self.lib.extractPath {
    path = "cover-benchmarks";
    src = fetchgit {
    name = "cover-benchmarks";
    url = "git://github.com/florence/cover.git";
    rev = "ad50ffa8f6246053bec24b39b9cae7fad1534373";
    sha256 = "1dhfk8fgwi4by3rjzkdf20b6kvy839k2xakcklsc25a1x8vn0l8w";
  };
  };
  racketThinBuildInputs = [ self."draw-lib" self."plot-lib" self."cover-lib" self."base" self."custom-load" self."pict-lib" self."pict-test" self."racket-benchmarks" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-cobertura" = self.lib.mkRacketDerivation rec {
  pname = "cover-cobertura";
  src = fetchgit {
    name = "cover-cobertura";
    url = "git://github.com/EFanZh/cover-cobertura.git";
    rev = "2a63c5ef4544b3c6ca928c596ae81e4490f14c14";
    sha256 = "14r1fvfcjvv75jxwrbrjh81jhfw4ac1l5h9gid0kjpdhj7322547";
  };
  racketThinBuildInputs = [ self."base" self."cover" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-codecov" = self.lib.mkRacketDerivation rec {
  pname = "cover-codecov";
  src = fetchgit {
    name = "cover-codecov";
    url = "git://github.com/florence/cover-codecov.git";
    rev = "b1a9de60da3c33894ddd6fcc3e26e8e6b614f708";
    sha256 = "0dawcl93yykmrgwcdkpm7qdgc5rarkpf3y12v3c9lbvf67sjiakg";
  };
  racketThinBuildInputs = [ self."cover-lib" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-coveralls" = self.lib.mkRacketDerivation rec {
  pname = "cover-coveralls";
  src = fetchgit {
    name = "cover-coveralls";
    url = "git://github.com/rpless/cover-coveralls";
    rev = "a5bb101d934e72f49b3f583707c58b921d61c07c";
    sha256 = "1gi4pgnxd32kpc5iqz6nvsnxiamahmd7kbwr1kx844x78ak8ki8f";
  };
  racketThinBuildInputs = [ self."base" self."cover-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-doc" = self.lib.mkRacketDerivation rec {
  pname = "cover-doc";
  src = self.lib.extractPath {
    path = "cover-doc";
    src = fetchgit {
    name = "cover-doc";
    url = "git://github.com/florence/cover.git";
    rev = "ad50ffa8f6246053bec24b39b9cae7fad1534373";
    sha256 = "1dhfk8fgwi4by3rjzkdf20b6kvy839k2xakcklsc25a1x8vn0l8w";
  };
  };
  racketThinBuildInputs = [ self."base" self."cover-lib" self."racket-doc" self."base" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-lib" = self.lib.mkRacketDerivation rec {
  pname = "cover-lib";
  src = self.lib.extractPath {
    path = "cover-lib";
    src = fetchgit {
    name = "cover-lib";
    url = "git://github.com/florence/cover.git";
    rev = "ad50ffa8f6246053bec24b39b9cae7fad1534373";
    sha256 = "1dhfk8fgwi4by3rjzkdf20b6kvy839k2xakcklsc25a1x8vn0l8w";
  };
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."custom-load" self."data-lib" self."errortrace-lib" self."syntax-color-lib" self."testing-util-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cover-test" = self.lib.mkRacketDerivation rec {
  pname = "cover-test";
  src = self.lib.extractPath {
    path = "cover-test";
    src = fetchgit {
    name = "cover-test";
    url = "git://github.com/florence/cover.git";
    rev = "ad50ffa8f6246053bec24b39b9cae7fad1534373";
    sha256 = "1dhfk8fgwi4by3rjzkdf20b6kvy839k2xakcklsc25a1x8vn0l8w";
  };
  };
  racketThinBuildInputs = [ self."base" self."cover-lib" self."data-lib" self."syntax-color-lib" self."compiler-lib" self."custom-load" self."at-exp-lib" self."base" self."htdp-lib" self."macro-debugger" self."rackunit-lib" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cow-repl" = self.lib.mkRacketDerivation rec {
  pname = "cow-repl";
  src = fetchgit {
    name = "cow-repl";
    url = "git://github.com/takikawa/racket-cow-repl.git";
    rev = "19b38c35a868d3e3fe02d4f5fcc59e8212c37228";
    sha256 = "1xziyrwbjbjhljbqmrlx73zpsi6vqsyj1xmjglfiwaf46sdrijcs";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cpu-affinity" = self.lib.mkRacketDerivation rec {
  pname = "cpu-affinity";
  src = fetchgit {
    name = "cpu-affinity";
    url = "git://github.com/takikawa/racket-cpu-affinity.git";
    rev = "bc6316cbc7bc3f2179ae569bfe7c23a53b62025f";
    sha256 = "1nr8il3vx7b4rkp5rc2qi391q5py7v27pbp7zgvadfa6l9bcxqd9";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."compatibility-lib" self."racket-doc" self."compatibility-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cpuinfo" = self.lib.mkRacketDerivation rec {
  pname = "cpuinfo";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/cpuinfo.zip";
    sha1 = "e5d01f97d71e0098ee6af20052889f52b94f5115";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."mcfly" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crc32c" = self.lib.mkRacketDerivation rec {
  pname = "crc32c";
  src = fetchgit {
    name = "crc32c";
    url = "https://bitbucket.org/Tetsumi/crc32c.git";
    rev = "9ae11530f64ae796e3280b224249f5157b7bdf04";
    sha256 = "11jrqymry1gdayaapll2mz3q51hix8d9gx6b46m0gg8cwdc6ina4";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crypto" = self.lib.mkRacketDerivation rec {
  pname = "crypto";
  src = self.lib.extractPath {
    path = "crypto";
    src = fetchgit {
    name = "crypto";
    url = "git://github.com/rmculpepper/crypto.git";
    rev = "981faedbbac33eb0120a30e36d7917cc4e9479fc";
    sha256 = "0wzimcndkcvr7nakq16ig4xsmiqmvnjmm407245sqmbwzv84090l";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."crypto-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crypto-doc" = self.lib.mkRacketDerivation rec {
  pname = "crypto-doc";
  src = self.lib.extractPath {
    path = "crypto-doc";
    src = fetchgit {
    name = "crypto-doc";
    url = "git://github.com/rmculpepper/crypto.git";
    rev = "981faedbbac33eb0120a30e36d7917cc4e9479fc";
    sha256 = "0wzimcndkcvr7nakq16ig4xsmiqmvnjmm407245sqmbwzv84090l";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."crypto-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crypto-lib" = self.lib.mkRacketDerivation rec {
  pname = "crypto-lib";
  src = self.lib.extractPath {
    path = "crypto-lib";
    src = fetchgit {
    name = "crypto-lib";
    url = "git://github.com/rmculpepper/crypto.git";
    rev = "981faedbbac33eb0120a30e36d7917cc4e9479fc";
    sha256 = "0wzimcndkcvr7nakq16ig4xsmiqmvnjmm407245sqmbwzv84090l";
  };
  };
  racketThinBuildInputs = [ self."base" self."asn1-lib" self."binaryio-lib" self."gmp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crypto-test" = self.lib.mkRacketDerivation rec {
  pname = "crypto-test";
  src = self.lib.extractPath {
    path = "crypto-test";
    src = fetchgit {
    name = "crypto-test";
    url = "git://github.com/rmculpepper/crypto.git";
    rev = "981faedbbac33eb0120a30e36d7917cc4e9479fc";
    sha256 = "0wzimcndkcvr7nakq16ig4xsmiqmvnjmm407245sqmbwzv84090l";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."asn1-lib" self."crypto-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "crystal" = self.lib.mkRacketDerivation rec {
  pname = "crystal";
  src = self.lib.extractPath {
    path = "crystal";
    src = fetchgit {
    name = "crystal";
    url = "https://gitlab.com/spritely/crystal.git";
    rev = "70274401f177b1001ea15169c9032e466bf8efc9";
    sha256 = "0lrfvwwqm45sl6qrrghmfz6qyd1qs4calxfjcfz0vxps10kgzx84";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."csexp" self."web-server-lib" self."magenc" self."html-writing" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cs-bootstrap" = self.lib.mkRacketDerivation rec {
  pname = "cs-bootstrap";
  src = self.lib.extractPath {
    path = "racket/src/cs/bootstrap";
    src = fetchgit {
    name = "cs-bootstrap";
    url = "git://github.com/racket/racket.git";
    rev = "d590eee0c773af8a1c530db244f0f1ddb29e7871";
    sha256 = "0pnkvhc6kb4493fhw4ajw1mqln8c5467k5kmcplbw4dm4nwchd60";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cs2500f16-jsonlab" = self.lib.mkRacketDerivation rec {
  pname = "cs2500f16-jsonlab";
  src = fetchgit {
    name = "cs2500f16-jsonlab";
    url = "git://github.com/rmacnz/cs2500jsonlab.git";
    rev = "34e5dceecc4b8c43428414b3da7befdb36c123d6";
    sha256 = "0ggc0wnr68lrskjy7rxn2dmpin55fh4hz6invr61jybn631ij46h";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cs7480-util" = self.lib.mkRacketDerivation rec {
  pname = "cs7480-util";
  src = fetchgit {
    name = "cs7480-util";
    url = "git://github.com/MiloDavis/cs7480-util.git";
    rev = "cd672fcb1f09354ef37619ddeed6c396286acfa5";
    sha256 = "11w1q202pfx190z6mpf9hz5x4kg6zwcbpn7n4i614wyq70k9c847";
  };
  racketThinBuildInputs = [ self."base" self."lang-file" self."typed-racket-lib" self."drracket-tool-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csc104" = self.lib.mkRacketDerivation rec {
  pname = "csc104";
  src = fetchurl {
    url = "https://www.cs.toronto.edu/~gfb/racket-pkgs/csc104.zip";
    sha1 = "f329049edf037b4d7b4bc624477e7759cffaca22";
  };
  racketThinBuildInputs = [ self."base" self."tightlight" self."snack" self."draw-lib" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."htdp-lib" self."images-lib" self."net-lib" self."reprovide-lang" self."snip-lib" self."option-contract-lib" self."parser-tools-lib" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csexp" = self.lib.mkRacketDerivation rec {
  pname = "csexp";
  src = self.lib.extractPath {
    path = "csexp";
    src = fetchgit {
    name = "csexp";
    url = "https://gitlab.com/spritely/racket-csexp.git";
    rev = "a5b054836db26c6568d88d4e6c7706ff270f83f4";
    sha256 = "0ybixnx65j7rpsh2rc606073gbvdspq5syndbn4x092v280m7xb8";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csfml" = self.lib.mkRacketDerivation rec {
  pname = "csfml";
  src = fetchgit {
    name = "csfml";
    url = "git://github.com/massung/racket-csfml.git";
    rev = "6bc3f07c335328f7b6d5d11d3f0f58cd52bcbd3f";
    sha256 = "1922a6x066pp4mnp5rb9i1b2f3yr6cqgsyv71lfaw9szabx5k6k9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csp" = self.lib.mkRacketDerivation rec {
  pname = "csp";
  src = fetchgit {
    name = "csp";
    url = "git://github.com/mbutterick/csp.git";
    rev = "4173bd69214a4f090bec0417454a5ecc3ad3e0af";
    sha256 = "0bnz7xisp0ymi6ilqw8s2qjc7qgq5b2zr3jqj136vzwsv16i4knh";
  };
  racketThinBuildInputs = [ self."beautiful-racket-lib" self."htdp-lib" self."math-lib" self."base" self."sugar" self."rackunit-lib" self."debug" self."graph" self."at-exp-lib" self."math-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csrmesh" = self.lib.mkRacketDerivation rec {
  pname = "csrmesh";
  src = fetchgit {
    name = "csrmesh";
    url = "https://gitlab.com/RayRacine/csrmesh.git";
    rev = "d7cc04b2bbfd45c71bf086bf5075de9ccd81415f";
    sha256 = "05hh23a0hkk5bvr1r3xnvpa4dk7d6ww73mhlq3hy16n7i4k2j0dh";
  };
  racketThinBuildInputs = [ self."crypto" self."bitsyntax" self."word" self."typed-racket-more" self."typed-racket-lib" self."base" self."scribble-lib" self."typed-racket-doc" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "css-expr" = self.lib.mkRacketDerivation rec {
  pname = "css-expr";
  src = fetchgit {
    name = "css-expr";
    url = "git://github.com/leafac/css-expr.git";
    rev = "d060b2a76d08013c91318890dc5d9f6cc6c81138";
    sha256 = "19mb0jfwp5d154hhqkvnixy37va36mqha5wcmc57lkirlgb2rdnp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."nanopass" self."scribble-lib" self."racket-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "css-tools" = self.lib.mkRacketDerivation rec {
  pname = "css-tools";
  src = fetchgit {
    name = "css-tools";
    url = "git://github.com/mbutterick/css-tools.git";
    rev = "a485024a1bab79afe2124db2d76b0bc5bd272f31";
    sha256 = "1hkxcff1f3mi51pbgh6gbyj5294y67g7x04gyk78jana11q0ib7i";
  };
  racketThinBuildInputs = [ self."base" self."sugar" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csv" = self.lib.mkRacketDerivation rec {
  pname = "csv";
  src = fetchgit {
    name = "csv";
    url = "git://github.com/halida/csv.git";
    rev = "c21cf591926b8c978b3191671ca50570fc50d21b";
    sha256 = "0srzi7rghl10mg0xmpwwysbqjm524cfylvz9cr5l5pccw0wsab91";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csv-reading" = self.lib.mkRacketDerivation rec {
  pname = "csv-reading";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/csv-reading.zip";
    sha1 = "217c1ee293ee246cba52fc91f2e897492d0b5101";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "csv-writing" = self.lib.mkRacketDerivation rec {
  pname = "csv-writing";
  src = fetchgit {
    name = "csv-writing";
    url = "git://github.com/jbclements/csv-writing.git";
    rev = "a656ce4ee8ee9ef618e257a9def8f673f3ec6122";
    sha256 = "112wcfvxvkrv4w4h4ri0bk4sa62rq1j2mpda30in4fn9i0axyv44";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cuecore" = self.lib.mkRacketDerivation rec {
  pname = "cuecore";
  src = fetchgit {
    name = "cuecore";
    url = "git://github.com/mordae/racket-cuecore.git";
    rev = "826b05916b9f84601ef405ee36e6b9a843c42ea2";
    sha256 = "1d1fmv6pf4c3dmg9gyv8qng6kmf9p0c3521nxmb5a8jfranxy5ij";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."mordae" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cur" = self.lib.mkRacketDerivation rec {
  pname = "cur";
  src = self.lib.extractPath {
    path = "cur";
    src = fetchgit {
    name = "cur";
    url = "git://github.com/wilbowma/cur.git";
    rev = "df31613b683244f4f56f9e1d562a22dcd982307d";
    sha256 = "0gkc1xill00gnxb21n6n75af157w984bhh6gh8x43wi0f2f1wkpb";
  };
  };
  racketThinBuildInputs = [ self."cur-lib" self."cur-doc" self."cur-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cur-doc" = self.lib.mkRacketDerivation rec {
  pname = "cur-doc";
  src = self.lib.extractPath {
    path = "cur-doc";
    src = fetchgit {
    name = "cur-doc";
    url = "git://github.com/wilbowma/cur.git";
    rev = "df31613b683244f4f56f9e1d562a22dcd982307d";
    sha256 = "0gkc1xill00gnxb21n6n75af157w984bhh6gh8x43wi0f2f1wkpb";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cur-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cur-lib" = self.lib.mkRacketDerivation rec {
  pname = "cur-lib";
  src = self.lib.extractPath {
    path = "cur-lib";
    src = fetchgit {
    name = "cur-lib";
    url = "git://github.com/wilbowma/cur.git";
    rev = "df31613b683244f4f56f9e1d562a22dcd982307d";
    sha256 = "0gkc1xill00gnxb21n6n75af157w984bhh6gh8x43wi0f2f1wkpb";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cur-test" = self.lib.mkRacketDerivation rec {
  pname = "cur-test";
  src = self.lib.extractPath {
    path = "cur-test";
    src = fetchgit {
    name = "cur-test";
    url = "git://github.com/wilbowma/cur.git";
    rev = "df31613b683244f4f56f9e1d562a22dcd982307d";
    sha256 = "0gkc1xill00gnxb21n6n75af157w984bhh6gh8x43wi0f2f1wkpb";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."cur-lib" self."sweet-exp-lib" self."chk-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "curly-fn" = self.lib.mkRacketDerivation rec {
  pname = "curly-fn";
  src = self.lib.extractPath {
    path = "curly-fn";
    src = fetchgit {
    name = "curly-fn";
    url = "git://github.com/lexi-lambda/racket-curly-fn.git";
    rev = "d64cd71d5b386be85f5979edae6f6b6469a4df86";
    sha256 = "1llxaykp1sbbqnm89ay6lcswfwjn594xsx491hw70l9g83yyivl1";
  };
  };
  racketThinBuildInputs = [ self."curly-fn-doc" self."curly-fn-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "curly-fn-doc" = self.lib.mkRacketDerivation rec {
  pname = "curly-fn-doc";
  src = self.lib.extractPath {
    path = "curly-fn-doc";
    src = fetchgit {
    name = "curly-fn-doc";
    url = "git://github.com/lexi-lambda/racket-curly-fn.git";
    rev = "d64cd71d5b386be85f5979edae6f6b6469a4df86";
    sha256 = "1llxaykp1sbbqnm89ay6lcswfwjn594xsx491hw70l9g83yyivl1";
  };
  };
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."namespaced-transformer-doc" self."namespaced-transformer-lib" self."racket-doc" self."scribble-code-examples" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "curly-fn-lib" = self.lib.mkRacketDerivation rec {
  pname = "curly-fn-lib";
  src = self.lib.extractPath {
    path = "curly-fn-lib";
    src = fetchgit {
    name = "curly-fn-lib";
    url = "git://github.com/lexi-lambda/racket-curly-fn.git";
    rev = "d64cd71d5b386be85f5979edae6f6b6469a4df86";
    sha256 = "1llxaykp1sbbqnm89ay6lcswfwjn594xsx491hw70l9g83yyivl1";
  };
  };
  racketThinBuildInputs = [ self."base" self."namespaced-transformer-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "curly-fn-test" = self.lib.mkRacketDerivation rec {
  pname = "curly-fn-test";
  src = self.lib.extractPath {
    path = "curly-fn-test";
    src = fetchgit {
    name = "curly-fn-test";
    url = "git://github.com/lexi-lambda/racket-curly-fn.git";
    rev = "d64cd71d5b386be85f5979edae6f6b6469a4df86";
    sha256 = "1llxaykp1sbbqnm89ay6lcswfwjn594xsx491hw70l9g83yyivl1";
  };
  };
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "curved-text" = self.lib.mkRacketDerivation rec {
  pname = "curved-text";
  src = fetchgit {
    name = "curved-text";
    url = "git://github.com/piotrklibert/curved-text.git";
    rev = "bc6223bfc3949bf2f632c86588f10f8da2ef0b6c";
    sha256 = "0jmm2jql5lv7zr0mrqrb04d6rqn1kpvs5bycw2ii2hy16gq13w9n";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "custom-load" = self.lib.mkRacketDerivation rec {
  pname = "custom-load";
  src = fetchgit {
    name = "custom-load";
    url = "git://github.com/rmculpepper/custom-load.git";
    rev = "4e70205c29ab0672663fcae78ded32563f01414b";
    sha256 = "0mnlsr91qcbppdisd01f5g7dyqn2j4sfy41lp917a29nl45cvrpg";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dali" = self.lib.mkRacketDerivation rec {
  pname = "dali";
  src = fetchgit {
    name = "dali";
    url = "git://github.com/johnstonskj/dali.git";
    rev = "d69925424559447fbd3bba7d4d66dcb2a745b9c2";
    sha256 = "1cc7gwp66xac47damncg99m30vrk649hl09q1xy2j5d3fdmy2bp5";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-index" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dan-scheme" = self.lib.mkRacketDerivation rec {
  pname = "dan-scheme";
  src = fetchgit {
    name = "dan-scheme";
    url = "git://github.com/david-christiansen/dan-scheme.git";
    rev = "f24fdf3569b718449b7dd64a14f5c53311dea057";
    sha256 = "0c7rm16srx98qzdnyv4p6w0w5wi2v35wsg29cdcggjhiicy6by5r";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "darwin" = self.lib.mkRacketDerivation rec {
  pname = "darwin";
  src = fetchgit {
    name = "darwin";
    url = "git://github.com/pmatos/darwin.git";
    rev = "001f75ac4c42274451b2f1010e7e1d87619e0caa";
    sha256 = "1x3yz9dz1dwfwxmv7gqv612qfyiymkk4c44jcidf7wz1qh8y5qrn";
  };
  racketThinBuildInputs = [ self."base" self."find-parent-dir" self."html-lib" self."markdown-ng" self."racket-index" self."rackjure" self."reprovide-lang" self."scribble-lib" self."scribble-text-lib" self."srfi-lite-lib" self."web-server-lib" self."at-exp-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."scribble-text-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data" = self.lib.mkRacketDerivation rec {
  pname = "data";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/data.zip";
    sha1 = "efa141d8beebd574abc6c093380f561d2c3522d6";
  };
  racketThinBuildInputs = [ self."data-lib" self."data-enumerate-lib" self."data-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-doc" = self.lib.mkRacketDerivation rec {
  pname = "data-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/data-doc.zip";
    sha1 = "df65bfb4fe3134f5159a9e9204110a5b5520ffab";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."data-lib" self."data-enumerate-lib" self."scribble-lib" self."plot-lib" self."math-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "data-enumerate-lib" = self.lib.mkRacketDerivation rec {
  pname = "data-enumerate-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/data-enumerate-lib.zip";
    sha1 = "e1e1deb4b85adae05f2b916d1447aa8704b3ef13";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."math-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-frame" = self.lib.mkRacketDerivation rec {
  pname = "data-frame";
  src = fetchgit {
    name = "data-frame";
    url = "git://github.com/alex-hhh/data-frame.git";
    rev = "120e80ea2b9051eb69473c21b1536e75fb3fb28c";
    sha256 = "1xfi8fxg7z90p7mqfpjif9f9pxd0bd706jk5zba243kb9wmipmk1";
  };
  racketThinBuildInputs = [ self."db-lib" self."draw-lib" self."math-lib" self."plot-gui-lib" self."plot-lib" self."srfi-lite-lib" self."typed-racket-lib" self."rackunit-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."db-doc" self."math-doc" self."plot-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-lib" = self.lib.mkRacketDerivation rec {
  pname = "data-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/data-lib.zip";
    sha1 = "7f614dc5c000e3ac770b448bcabe7c4824084c2a";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-red-black" = self.lib.mkRacketDerivation rec {
  pname = "data-red-black";
  src = fetchgit {
    name = "data-red-black";
    url = "git://github.com/dyoo/data-red-black.git";
    rev = "d473dd82c5406c8954f70060fe3764bf72d92a90";
    sha256 = "1s19q718ac26cpzm0gqxp8n3ywqqp5pm9i96hnv9gyrfrh8836ah";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."data-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-table" = self.lib.mkRacketDerivation rec {
  pname = "data-table";
  src = fetchgit {
    name = "data-table";
    url = "git://github.com/jadudm/data-table.git";
    rev = "331dcd445372435abcca64e4eb75c8d34a73fe5b";
    sha256 = "17ah3mxrsinqflsm90q76xg66chq49nb32r6hf4r54bp5nccf5yb";
  };
  racketThinBuildInputs = [ self."db" self."data-lib" self."csv-reading" self."gregor" self."rackunit" self."rackunit-chk" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-test" = self.lib.mkRacketDerivation rec {
  pname = "data-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/data-test.zip";
    sha1 = "530a2a6924c6dd0e33e67e4c9db586ca876ab2eb";
  };
  racketThinBuildInputs = [ self."base" self."data-enumerate-lib" self."racket-index" self."data-lib" self."rackunit-lib" self."math-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "database-url" = self.lib.mkRacketDerivation rec {
  pname = "database-url";
  src = fetchgit {
    name = "database-url";
    url = "git://github.com/lassik/racket-database-url.git";
    rev = "89110683d2014b9e16f30210636a5f8eabd3cdbd";
    sha256 = "0blv84xpgx168fbmbfh8yi7bav0qirhwigq5yrnb1l0gx62743bb";
  };
  racketThinBuildInputs = [ self."db-lib" self."rackunit-lib" self."base" self."db-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "datacell" = self.lib.mkRacketDerivation rec {
  pname = "datacell";
  src = fetchgit {
    name = "datacell";
    url = "git://github.com/florence/datacell.git";
    rev = "fe91d9251542df5f9edb41fb457fb6c7f548d425";
    sha256 = "1zqxzwwm4pwrrsbrn9ajb4nwsic3hnd79fc3nmdnlz2ysx2wnli5";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "datalog" = self.lib.mkRacketDerivation rec {
  pname = "datalog";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/datalog.zip";
    sha1 = "9402c38facced8f50be809ddb4eaf30c008787b5";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."syntax-color-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "datatype" = self.lib.mkRacketDerivation rec {
  pname = "datatype";
  src = fetchgit {
    name = "datatype";
    url = "git://github.com/pnwamk/datatype";
    rev = "fda1df0f803fb7e4c33ea25697e1291edc9b6d3d";
    sha256 = "010sw6ljqk87z06rzic8p7wcjbii8rg2y7jvgxqsk5y3ash707da";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "date" = self.lib.mkRacketDerivation rec {
  pname = "date";
  src = fetchgit {
    name = "date";
    url = "https://gitlab.com/RayRacine/date.git";
    rev = "57d7adbbc09dffc26337bff1b1a3597c872be8ea";
    sha256 = "11bfr9l3krj71i2zwdmzxh2qc1sxi4k4pqy8hwrg40iysd5hkvnl";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."typed-racket-lib" self."base" self."srfi-lite-lib" self."typed-racket-more" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db" = self.lib.mkRacketDerivation rec {
  pname = "db";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db.zip";
    sha1 = "1514366b5ed8eade9c809712fa9deb31b5b6be1f";
  };
  racketThinBuildInputs = [ self."db-lib" self."db-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-doc" = self.lib.mkRacketDerivation rec {
  pname = "db-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-doc.zip";
    sha1 = "3921716458a2d4802602e54a7e168da01024cbc8";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."srfi-lite-lib" self."base" self."scribble-lib" self."sandbox-lib" self."web-server-lib" self."db-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "db-lib" = self.lib.mkRacketDerivation rec {
  pname = "db-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-lib.zip";
    sha1 = "07ccccda49c25c28b269b1d5b2a4bfce53916d20";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."unix-socket-lib" self."sasl-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "db-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-ppc-macosx.zip";
    sha1 = "a8e944afb21b3e7b1d14ff16553ffd5a71645dba";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-test" = self.lib.mkRacketDerivation rec {
  pname = "db-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-test.zip";
    sha1 = "0b55665a04e5b6f87b160229a37a79a4170c04f6";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."rackunit-lib" self."web-server-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "db-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-win32-i386.zip";
    sha1 = "6c93871dd5b380ff5a9c01d7ebb380573d300af4";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "db-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-win32-x86_64.zip";
    sha1 = "4cfadee0b6fb3223e657b603987094f7a58cded8";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "db-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/db-x86_64-linux-natipkg.zip";
    sha1 = "99877935eb599bd116642bcddf1253f885c43e86";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dbm" = self.lib.mkRacketDerivation rec {
  pname = "dbm";
  src = fetchgit {
    name = "dbm";
    url = "git://github.com/jeapostrophe/dbm.git";
    rev = "a5bf5a400457f49e3e8f5b2009f97e6c4494d1c6";
    sha256 = "166gy5pw0fv71w26dsgn3n9ljv50pk03ld196bahi8m3hpay4y34";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dbus" = self.lib.mkRacketDerivation rec {
  pname = "dbus";
  src = fetchgit {
    name = "dbus";
    url = "git://github.com/tonyg/racket-dbus.git";
    rev = "57c5e3d9120f778b48ba01efb6b37c1ffbc9963d";
    sha256 = "1kiam2j1yypf0x6x5v5q2cqgm7rq38q6lj3qvk589b50yzlpw550";
  };
  racketThinBuildInputs = [ self."xexpr-path" self."misc1" self."base" self."parser-tools-lib" self."unstable-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ddict" = self.lib.mkRacketDerivation rec {
  pname = "ddict";
  src = fetchgit {
    name = "ddict";
    url = "git://github.com/pnwamk/ddict.git";
    rev = "a322d6a38c203d946d48d3ae5892e9ad4f11bdf2";
    sha256 = "010zp94iwm5275hclcs5ivn27dw0hw7k6w4lc93gbklqq0rwnlk7";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "debug" = self.lib.mkRacketDerivation rec {
  pname = "debug";
  src = fetchgit {
    name = "debug";
    url = "git://github.com/AlexKnauth/debug.git";
    rev = "aa798842c09ece55c2a088f09d30e398d2b77fee";
    sha256 = "1vq5sj6ycn6pbclvd59nriayv8sb3y9gqh4vl5p2l11gawzxr9yc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."pretty-format" self."rackunit-lib" self."rackunit-typed" self."scribble-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "debug-scopes" = self.lib.mkRacketDerivation rec {
  pname = "debug-scopes";
  src = fetchgit {
    name = "debug-scopes";
    url = "git://github.com/jsmaniac/debug-scopes.git";
    rev = "ad12bbfc218c0153cc3fa9410e0c025dc21e3ca9";
    sha256 = "0h20sirwkkccadfp5h9mrs662ys34lyimb03j7qrfxsnb7ip2nnv";
  };
  racketThinBuildInputs = [ self."base" self."pretty-format" self."rackunit-lib" self."reprovide-lang" self."scribble-lib" self."racket-doc" self."scribble-enhanced" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "decentralized-internet" = self.lib.mkRacketDerivation rec {
  pname = "decentralized-internet";
  src = fetchgit {
    name = "decentralized-internet";
    url = "git://github.com/Lonero-Team/Racket-Package.git";
    rev = "74f1c6d7f51102e5b2e7ed6a609cc39b930dfb7c";
    sha256 = "1jxvqfb7j39d0a90dzp0vhl3bxbkqw2vlqq0iqrcwdkq7yc0m21z";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deferred" = self.lib.mkRacketDerivation rec {
  pname = "deferred";
  src = fetchgit {
    name = "deferred";
    url = "git://github.com/cjfuller/deferred.git";
    rev = "fccb728dc9cbc0a6acb38fd0bc782db41bf32d4c";
    sha256 = "0a7f7ymgmdjgwm0d5ij8f4hcqcggwqlsd8cc9d6dqmcx7lccph1b";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "define-assets-from" = self.lib.mkRacketDerivation rec {
  pname = "define-assets-from";
  src = fetchgit {
    name = "define-assets-from";
    url = "git://github.com/thoughtstem/define-assets-from.git";
    rev = "f41954f7d955fdabbd697976d73344a5aa733d31";
    sha256 = "1y5w06iccci1klj6zypz2rgwn57yxm9wvls8zvnzn991qr316arw";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "define-match-spread-out" = self.lib.mkRacketDerivation rec {
  pname = "define-match-spread-out";
  src = fetchgit {
    name = "define-match-spread-out";
    url = "git://github.com/AlexKnauth/define-match-spread-out.git";
    rev = "0f97b9f4bdee1655617f70f4291cf774993b2f83";
    sha256 = "1i0rprhgq2lnqxlyx2q827xs08wjyil041hfz8gjya7yim5fdi38";
  };
  racketThinBuildInputs = [ self."base" self."unstable-lib" self."defpat" self."rackunit-lib" self."scribble-lib" self."scribble-code-examples" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "define-with-spec" = self.lib.mkRacketDerivation rec {
  pname = "define-with-spec";
  src = fetchgit {
    name = "define-with-spec";
    url = "git://github.com/pnwamk/define-with-spec.git";
    rev = "1b7050a848a853313abb5cdd4a0bfcb6705e5f9f";
    sha256 = "01xdc3j5qp6q316f6f0as1rggk40146l64gqy1adnl88cgbw3pa6";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "defpat" = self.lib.mkRacketDerivation rec {
  pname = "defpat";
  src = fetchgit {
    name = "defpat";
    url = "git://github.com/AlexKnauth/defpat.git";
    rev = "b1ab923ef4c92355de7ee77703d8af692835c8f0";
    sha256 = "0v1bwm96x87dkiays6rswby685rkngn9l0w5q3ngbglba6vc42sn";
  };
  racketThinBuildInputs = [ self."base" self."generic-bind" self."sweet-exp" self."reprovide-lang" self."unstable-lib" self."unstable-list-lib" self."rackunit" self."scribble-lib" self."scribble-code-examples" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deinprogramm" = self.lib.mkRacketDerivation rec {
  pname = "deinprogramm";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/deinprogramm.zip";
    sha1 = "2c1a999fa2d57512d20d1790f39805cc795fd72b";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."deinprogramm-signature" self."drracket" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."htdp-lib" self."pconvert-lib" self."scheme-lib" self."string-constants-lib" self."trace" self."wxme-lib" self."at-exp-lib" self."htdp-doc" self."racket-doc" self."racket-index" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deinprogramm-signature" = self.lib.mkRacketDerivation rec {
  pname = "deinprogramm-signature";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/deinprogramm-signature.zip";
    sha1 = "122ec1b39094cddb7a4c2bec3224bfd91590dfc7";
  };
  racketThinBuildInputs = [ self."deinprogramm-signature+htdp-lib" self."base" self."compatibility-lib" self."drracket-plugin-lib" self."gui-lib" self."scheme-lib" self."srfi-lib" self."string-constants-lib" ];
  circularBuildInputs = [ "htdp-lib" "deinprogramm-signature" ];
  reverseCircularBuildInputs = [  ];
  };
  "deinprogramm-signature+htdp-lib" = self.lib.mkRacketDerivation rec {
  pname = "deinprogramm-signature+htdp-lib";

  extraSrcs = [ self."htdp-lib".src self."deinprogramm-signature".src ];
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."compatibility-lib" self."draw-lib" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."html-lib" self."images-gui-lib" self."images-lib" self."net-lib" self."pconvert-lib" self."pict-lib" self."plai-lib" self."r5rs-lib" self."racket-index" self."rackunit-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."slideshow-lib" self."snip-lib" self."srfi-lib" self."srfi-lite-lib" self."string-constants-lib" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."wxme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "htdp-lib" "deinprogramm-signature" ];
  };
  "delay-pure" = self.lib.mkRacketDerivation rec {
  pname = "delay-pure";
  src = fetchgit {
    name = "delay-pure";
    url = "git://github.com/jsmaniac/delay-pure.git";
    rev = "98766ec6271012e2635aeabbf2bd3e1bd9ab68e1";
    sha256 = "01dss58q1r69zb6x07i8hdq7c1wqkfwrdjkxfagxabq1pm0qp2dy";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."type-expander" self."phc-toolkit" self."version-case" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "delimit-app" = self.lib.mkRacketDerivation rec {
  pname = "delimit-app";
  src = fetchgit {
    name = "delimit-app";
    url = "git://github.com/jackfirth/delimit-app.git";
    rev = "720c0f95c1c3642b936030fabfb4850ab166d7e2";
    sha256 = "0rk2ji1y341cql0fjcq4z7cmlpa5ynncm7a3vls3blpic8jnkrn9";
  };
  racketThinBuildInputs = [ self."base" self."fancy-app" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "derp-3" = self.lib.mkRacketDerivation rec {
  pname = "derp-3";
  src = fetchgit {
    name = "derp-3";
    url = "https://bitbucket.org/jbclements/derp-3.git";
    rev = "b26498d7bc7ab09a17b799c0e295f8e514930ca4";
    sha256 = "0lsqvn7p64q76v7c2xjcyz7yz2qp8l5yhlglcvkzsczx5khzplxr";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."srfi-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "derpy" = self.lib.mkRacketDerivation rec {
  pname = "derpy";
  src = fetchgit {
    name = "derpy";
    url = "git://github.com/mordae/racket-derpy.git";
    rev = "179ec02668cdb0beda40022ef9b45909795c7c09";
    sha256 = "1zjxglr7ymn43ir8za625zrviw853v3g4spw94ci8vpg72q85xzj";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."mordae" self."zmq" self."tesira" self."libserialport" self."esc-vp21" self."pex" self."cuecore" self."racket-doc" self."typed-racket-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "describe" = self.lib.mkRacketDerivation rec {
  pname = "describe";
  src = fetchgit {
    name = "describe";
    url = "git://github.com/mbutterick/describe.git";
    rev = "be266809f5b331e12bf18bdeee2495119060b0d4";
    sha256 = "0dqs9cdk5ifzazjayndb79ppwdcwcvzcf555wybd341k1f591ksg";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "design-by-numbers" = self.lib.mkRacketDerivation rec {
  pname = "design-by-numbers";
  src = self.lib.extractPath {
    path = "dbn";
    src = fetchgit {
    name = "design-by-numbers";
    url = "git://github.com/chrisgd/design-by-numbers.git";
    rev = "dc6e30cce44918090094f9c876746f98faea0cd0";
    sha256 = "1r52yfpb529wgc8i00x80aw3p8w32d66x98bxbi1k6g9cjagm4j9";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."parser-tools-lib" self."gui-lib" self."syntax-color-lib" self."wxme-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deta" = self.lib.mkRacketDerivation rec {
  pname = "deta";
  src = self.lib.extractPath {
    path = "deta";
    src = fetchgit {
    name = "deta";
    url = "git://github.com/Bogdanp/deta.git";
    rev = "dd356a116ac7ba23edb10e4976ffcff26966ada2";
    sha256 = "14jg54gg3lxx2717v1ly9g7v3r4zvvf72gr68fnzmvm0ksi2s9cy";
  };
  };
  racketThinBuildInputs = [ self."deta-doc" self."deta-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deta-doc" = self.lib.mkRacketDerivation rec {
  pname = "deta-doc";
  src = self.lib.extractPath {
    path = "deta-doc";
    src = fetchgit {
    name = "deta-doc";
    url = "git://github.com/Bogdanp/deta.git";
    rev = "dd356a116ac7ba23edb10e4976ffcff26966ada2";
    sha256 = "14jg54gg3lxx2717v1ly9g7v3r4zvvf72gr68fnzmvm0ksi2s9cy";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-doc" self."db-lib" self."deta-lib" self."gregor-doc" self."gregor-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" self."threading-doc" self."threading-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deta-lib" = self.lib.mkRacketDerivation rec {
  pname = "deta-lib";
  src = self.lib.extractPath {
    path = "deta-lib";
    src = fetchgit {
    name = "deta-lib";
    url = "git://github.com/Bogdanp/deta.git";
    rev = "dd356a116ac7ba23edb10e4976ffcff26966ada2";
    sha256 = "14jg54gg3lxx2717v1ly9g7v3r4zvvf72gr68fnzmvm0ksi2s9cy";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."gregor-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deta-test" = self.lib.mkRacketDerivation rec {
  pname = "deta-test";
  src = self.lib.extractPath {
    path = "deta-test";
    src = fetchgit {
    name = "deta-test";
    url = "git://github.com/Bogdanp/deta.git";
    rev = "dd356a116ac7ba23edb10e4976ffcff26966ada2";
    sha256 = "14jg54gg3lxx2717v1ly9g7v3r4zvvf72gr68fnzmvm0ksi2s9cy";
  };
  };
  racketThinBuildInputs = [ self."libsqlite3-x86_64-linux" self."base" self."at-exp-lib" self."db-lib" self."deta-lib" self."gregor-lib" self."rackunit-lib" self."threading-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "detail" = self.lib.mkRacketDerivation rec {
  pname = "detail";
  src = fetchgit {
    name = "detail";
    url = "git://github.com/simmone/racket-detail.git";
    rev = "8c2355c313e98f04432c47bb25403c844a77f2eb";
    sha256 = "00lsfrd6c7g5fwsy6nd5glb5bb8b1gx4h8hxxqli36j68j19a7f3";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dherman-struct" = self.lib.mkRacketDerivation rec {
  pname = "dherman-struct";
  src = fetchgit {
    name = "dherman-struct";
    url = "git://github.com/jbclements/dherman-struct.git";
    rev = "1f0510d8e50ca3d22b3ba7ee65cce117450d44a0";
    sha256 = "0dhf4farzf334axqnnmmj0bi0bxlqsjy4szvpljilwxpsxxdwf2z";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scheme-lib" self."rackunit-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "diagrama" = self.lib.mkRacketDerivation rec {
  pname = "diagrama";
  src = self.lib.extractPath {
    path = "diagrama";
    src = fetchgit {
    name = "diagrama";
    url = "git://github.com/florence/diagrama.git";
    rev = "291f244843d7226df4b7cb763bc3d6b1e98af71b";
    sha256 = "1qcarax3m1n4564krf5svzgcxbca2bcw4b96p1k2y8r91d218ac2";
  };
  };
  racketThinBuildInputs = [ self."base" self."diagrama-lib" self."diagrama-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "diagrama-doc" = self.lib.mkRacketDerivation rec {
  pname = "diagrama-doc";
  src = self.lib.extractPath {
    path = "diagrama-doc";
    src = fetchgit {
    name = "diagrama-doc";
    url = "git://github.com/florence/diagrama.git";
    rev = "291f244843d7226df4b7cb763bc3d6b1e98af71b";
    sha256 = "1qcarax3m1n4564krf5svzgcxbca2bcw4b96p1k2y8r91d218ac2";
  };
  };
  racketThinBuildInputs = [ self."base" self."diagrama-lib" self."pict-lib" self."draw-doc" self."draw-lib" self."pict-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "diagrama-lib" = self.lib.mkRacketDerivation rec {
  pname = "diagrama-lib";
  src = self.lib.extractPath {
    path = "diagrama-lib";
    src = fetchgit {
    name = "diagrama-lib";
    url = "git://github.com/florence/diagrama.git";
    rev = "291f244843d7226df4b7cb763bc3d6b1e98af71b";
    sha256 = "1qcarax3m1n4564krf5svzgcxbca2bcw4b96p1k2y8r91d218ac2";
  };
  };
  racketThinBuildInputs = [ self."draw-lib" self."base" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "diagrams" = self.lib.mkRacketDerivation rec {
  pname = "diagrams";
  src = fetchgit {
    name = "diagrams";
    url = "git://github.com/dedbox/racket-diagrams.git";
    rev = "ab990ea081e982f7216ed9f7ff3c8e44749cd645";
    sha256 = "1wi5yljhrxnf97nkmpyfsqi770r2qych4pwyaqd24cm32g4ky3h3";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dice-parser" = self.lib.mkRacketDerivation rec {
  pname = "dice-parser";
  src = fetchgit {
    name = "dice-parser";
    url = "https://gitlab.com/car.margiotta/dice-parser.git";
    rev = "46a1b1fa1f2a74a3f2053adfc03171d19712c145";
    sha256 = "0w3p64f8nzlvy147jhhlil51nbxsvljs6bbp8iqvimmzmhmx817h";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "diff-merge" = self.lib.mkRacketDerivation rec {
  pname = "diff-merge";
  src = fetchgit {
    name = "diff-merge";
    url = "git://github.com/tonyg/racket-diff-merge.git";
    rev = "13a367d6f254ac184f017b37f5e204ac6c95dabe";
    sha256 = "0k2h00csbfazj3cgdjax9d6s3vq1lsc4ygb9xnfzqbwvlnsfwgpf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "digimon" = self.lib.mkRacketDerivation rec {
  pname = "digimon";
  src = fetchgit {
    name = "digimon";
    url = "git://github.com/wargrey/digimon.git";
    rev = "f7c31b2a3b9dc97b3c3115f2c7dabdb927dd84e4";
    sha256 = "1z12m33jc1cmjm4gwvss8km3gnlr0n7763pjr220l1rl0i5dri3n";
  };
  racketThinBuildInputs = [ self."base" self."make" self."typed-racket-lib" self."typed-racket-more" self."racket-index" self."sandbox-lib" self."scribble-lib" self."math-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "disassemble" = self.lib.mkRacketDerivation rec {
  pname = "disassemble";
  src = fetchgit {
    name = "disassemble";
    url = "git://github.com/samth/disassemble.git";
    rev = "2bf2d8c5dc07ec535ba008c7585c6d5cb12d10e6";
    sha256 = "0b3k1h3sn7fjbhblfx8li3mh29j0kq69hx3val3jnb0bvghbqllj";
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" self."srfi-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "disposable" = self.lib.mkRacketDerivation rec {
  pname = "disposable";
  src = self.lib.extractPath {
    path = "disposable";
    src = fetchgit {
    name = "disposable";
    url = "git://github.com/jackfirth/racket-disposable.git";
    rev = "843d3e224fd874b9c463b74cb5ef13d8a0b5766a";
    sha256 = "1dbh2nrknlbq9cy9h3hhyc21xix33ck84zxw915y3yvmm7klxbk2";
  };
  };
  racketThinBuildInputs = [ self."arguments" self."base" self."reprovide-lang" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."scribble-text-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "disposable-test" = self.lib.mkRacketDerivation rec {
  pname = "disposable-test";
  src = self.lib.extractPath {
    path = "disposable-test";
    src = fetchgit {
    name = "disposable-test";
    url = "git://github.com/jackfirth/racket-disposable.git";
    rev = "843d3e224fd874b9c463b74cb5ef13d8a0b5766a";
    sha256 = "1dbh2nrknlbq9cy9h3hhyc21xix33ck84zxw915y3yvmm7klxbk2";
  };
  };
  racketThinBuildInputs = [ self."base" self."disposable" self."doc-coverage" self."fixture" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distributed-places.zip";
    sha1 = "fc16d0a608c0903bc66756e43ccefb1bb81a032a";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."distributed-places-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places-doc" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distributed-places-doc.zip";
    sha1 = "c85adf5d4e99f7b703d6935be680f9c7cea063e7";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."distributed-places-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places-lib" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distributed-places-lib.zip";
    sha1 = "5a04b94d56ea6883aee958b58d4fabd73089d8e8";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places-test" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places-test";
  src = self.lib.extractPath {
    path = "distributed-places-test";
    src = fetchgit {
    name = "distributed-places-test";
    url = "git://github.com/racket/distributed-places.git";
    rev = "3f4a1f43430216871e8cc7a6ecbd2a03530a9bfb";
    sha256 = "00mbc3vg1r00frhixmg34i9wfdjavrwwpi6msryd70fcymrgh3in";
  };
  };
  racketThinBuildInputs = [ self."distributed-places-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build" = self.lib.mkRacketDerivation rec {
  pname = "distro-build";
  src = self.lib.extractPath {
    path = "distro-build";
    src = fetchgit {
    name = "distro-build";
    url = "git://github.com/racket/distro-build.git";
    rev = "f3e29f1b9dd8aa8f8c7291b63f75f3f00796a85a";
    sha256 = "1k3lcdbk433hrgbzz06zjayzfcxj4ckjz86krn8bs4whka2mmqsd";
  };
  };
  racketThinBuildInputs = [ self."distro-build-lib" self."distro-build-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-client" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-client";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distro-build-client.zip";
    sha1 = "c47b9c088b527dbd35ad565e3194d2ae2e2f2600";
  };
  racketThinBuildInputs = [ self."base" self."ds-store-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-doc" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-doc";
  src = self.lib.extractPath {
    path = "distro-build-doc";
    src = fetchgit {
    name = "distro-build-doc";
    url = "git://github.com/racket/distro-build.git";
    rev = "f3e29f1b9dd8aa8f8c7291b63f75f3f00796a85a";
    sha256 = "1k3lcdbk433hrgbzz06zjayzfcxj4ckjz86krn8bs4whka2mmqsd";
  };
  };
  racketThinBuildInputs = [ self."base" self."distro-build-server" self."distro-build-client" self."web-server-lib" self."at-exp-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-lib" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distro-build-lib.zip";
    sha1 = "3d84148fb9506c2d981fb2c71c94f374d5f51936";
  };
  racketThinBuildInputs = [ self."distro-build-client" self."distro-build-server" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-server" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-server";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/distro-build-server.zip";
    sha1 = "e8ac7ce4a7eb1a459108ef2612854c038bdb76ce";
  };
  racketThinBuildInputs = [ self."base" self."distro-build-client" self."web-server-lib" self."ds-store-lib" self."net-lib" self."scribble-html-lib" self."plt-web-lib" self."remote-shell-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-test" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-test";
  src = self.lib.extractPath {
    path = "distro-build-test";
    src = fetchgit {
    name = "distro-build-test";
    url = "git://github.com/racket/distro-build.git";
    rev = "f3e29f1b9dd8aa8f8c7291b63f75f3f00796a85a";
    sha256 = "1k3lcdbk433hrgbzz06zjayzfcxj4ckjz86krn8bs4whka2mmqsd";
  };
  };
  racketThinBuildInputs = [ self."base" self."remote-shell-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dlm-read" = self.lib.mkRacketDerivation rec {
  pname = "dlm-read";
  src = fetchgit {
    name = "dlm-read";
    url = "git://github.com/LeifAndersen/racket-dlm-read";
    rev = "9ae0487b315e762d311ea0e14b72a9bd2de27470";
    sha256 = "1rbqqsaqa1pycd4d8j668pxx4w35k8adsyqpi2jp3yz35d1j7lsi";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."csv-reading" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dm" = self.lib.mkRacketDerivation rec {
  pname = "dm";
  src = fetchgit {
    name = "dm";
    url = "git://github.com/mordae/racket-dm.git";
    rev = "15b137ef72b0bf1f10cfd1d14e80e2472e8a5df4";
    sha256 = "09dhdgkcpqybfrnnynn9028gsc84khplni0i7wgqx73pgmqs80cy";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."libuuid" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "doc-coverage" = self.lib.mkRacketDerivation rec {
  pname = "doc-coverage";
  src = self.lib.extractPath {
    path = "doc-coverage";
    src = fetchgit {
    name = "doc-coverage";
    url = "git://github.com/jackfirth/doc-coverage.git";
    rev = "b9b9f5df4e6aa640dbd14006c631f5194f5ad929";
    sha256 = "1jjf5p9vc5w39n9vg9lnqa0x1c9pmk76npa5xrpgjfrq70saaw9j";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."rackunit-lib" self."reprovide-lang-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "doodle" = self.lib.mkRacketDerivation rec {
  pname = "doodle";
  src = fetchgit {
    name = "doodle";
    url = "git://github.com/LeifAndersen/doodle.git";
    rev = "a6840bb97bb384b92c612960aca676e31662453c";
    sha256 = "1bl775bkckaiplglbsf5bq98mznlm9f2g887lphcb5nn22lmsfgf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."pict-lib" self."draw-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dos" = self.lib.mkRacketDerivation rec {
  pname = "dos";
  src = fetchgit {
    name = "dos";
    url = "git://github.com/jeapostrophe/dos.git";
    rev = "e39826f5f65f7d0b849e5286859e70a62a985be1";
    sha256 = "0a958f9dbzy73dx9q5sdnhwxvv986r90bqd7girki7lnhjrk3ckg";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."htdp-lib" self."scribble-lib" self."racket-doc" self."htdp-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dotenv" = self.lib.mkRacketDerivation rec {
  pname = "dotenv";
  src = fetchgit {
    name = "dotenv";
    url = "git://github.com/royallthefourth/dotenv.git";
    rev = "86b9a0718f2dfdae1b08d7f6f859875a06817de4";
    sha256 = "0j0b6spa8r7xzpjdrrnmkdjgsc89f2cyx595ya5py858ixqz2h3q";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dotlambda" = self.lib.mkRacketDerivation rec {
  pname = "dotlambda";
  src = fetchgit {
    name = "dotlambda";
    url = "git://github.com/jsmaniac/dotlambda.git";
    rev = "fed2278132fa30ac69b73c3f1400b15860a5a4a6";
    sha256 = "1bp85x9f7j8qr3dkk2cl83j1lbjk15y5dvzvxfxly22qsbf4wn9w";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-map-lib" self."typed-racket-lib" self."typed-racket-more" self."chain-module-begin" self."debug-scopes" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dotmethod" = self.lib.mkRacketDerivation rec {
  pname = "dotmethod";
  src = fetchgit {
    name = "dotmethod";
    url = "git://github.com/AlexKnauth/dotmethod.git";
    rev = "e427237130d9b530d935269a6506c8cdeccc765c";
    sha256 = "11q2f3b599r8jwwhhczgk74dyq6b50r9z75850ks8j54ngllnm72";
  };
  racketThinBuildInputs = [ self."base" self."afl" self."postfix-dot-notation" self."sweet-exp" self."mutable-match-lambda" self."my-cond" self."racket-doc" self."rackunit-lib" self."scribble-code-examples" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dracula-theme" = self.lib.mkRacketDerivation rec {
  pname = "dracula-theme";
  src = fetchgit {
    name = "dracula-theme";
    url = "git://github.com/massung/racket-dracula.git";
    rev = "93ee37d4d35d4ec117305c99c264bf9a0e58e622";
    sha256 = "09f76w6d7b2j45lckz48nc5hjj8034ibj8jxq0s1zlxqw16fihsj";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw" = self.lib.mkRacketDerivation rec {
  pname = "draw";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw.zip";
    sha1 = "13ac8b897da54e6d556894d0d0c7d24b17072eb5";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."draw-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-doc" = self.lib.mkRacketDerivation rec {
  pname = "draw-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-doc.zip";
    sha1 = "d712310a23abc9199567232255d6dd7d55b80a40";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."at-exp-lib" self."base" self."gui-lib" self."pict-lib" self."scribble-lib" self."draw-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "draw-i386-macosx";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/84ccf524cd10ad0c989eb37d816893dc0b26d705/draw-i386-macosx.zip";
    sha1 = "84ccf524cd10ad0c989eb37d816893dc0b26d705";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-i386-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-i386-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/e7c6929139d44373b86e437e1c46e9b02d0e051f/draw-i386-macosx-2.zip";
    sha1 = "e7c6929139d44373b86e437e1c46e9b02d0e051f";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-i386-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-i386-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-i386-macosx-3.zip";
    sha1 = "a27434a26812d0a4cbafa694b83e47ea52e328a3";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-lib" = self.lib.mkRacketDerivation rec {
  pname = "draw-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-lib.zip";
    sha1 = "760bba36086962e13826dee84bf82d289578009b";
  };
  racketThinBuildInputs = [ self."base" self."draw-i386-macosx-3" self."draw-x86_64-macosx-3" self."draw-ppc-macosx-3" self."draw-win32-i386-3" self."draw-win32-x86_64-3" self."draw-x86_64-linux-natipkg-3" self."draw-x11-x86_64-linux-natipkg" self."draw-ttf-x86_64-linux-natipkg" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "draw-ppc-macosx";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/ca120b25f76730e26a28f919a55e9defd455e10c/draw-ppc-macosx.zip";
    sha1 = "ca120b25f76730e26a28f919a55e9defd455e10c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-ppc-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-ppc-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/2f48dff527db9f3fcff4945fb9738cf352ea4399/draw-ppc-macosx-2.zip";
    sha1 = "2f48dff527db9f3fcff4945fb9738cf352ea4399";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-ppc-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-ppc-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-ppc-macosx-3.zip";
    sha1 = "4b0b9d0596c2435d16f8c330676a3fe62cef84a6";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-test" = self.lib.mkRacketDerivation rec {
  pname = "draw-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-test.zip";
    sha1 = "8dfdf2ec79bbd4941e970fba5f87de44180bfea6";
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."scheme-lib" self."draw-lib" self."racket-test" self."sgl" self."gui-lib" self."rackunit-lib" self."pconvert-lib" self."compatibility-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-ttf-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "draw-ttf-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-ttf-x86_64-linux-natipkg.zip";
    sha1 = "b799cd4955cfc63a63e5f2e2d5343bd90695e9eb";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-i386";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/f38adc9da2396b6efa0b221d8d3df43005c3558e/draw-win32-i386.zip";
    sha1 = "f38adc9da2396b6efa0b221d8d3df43005c3558e";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-i386-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-i386-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/fc0488d019932b7754657fa26ad7883931234584/draw-win32-i386-2.zip";
    sha1 = "fc0488d019932b7754657fa26ad7883931234584";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-i386-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-i386-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-win32-i386-3.zip";
    sha1 = "b9968794a7c778d60712041ae075eab91e9c1cd0";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-x86_64";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/ff0e422298ba0ead55f50f62be0a0ebaff90b59b/draw-win32-x86_64.zip";
    sha1 = "ff0e422298ba0ead55f50f62be0a0ebaff90b59b";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-x86_64-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-x86_64-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/e75d6188f943fbca5d97696411f07f8084107777/draw-win32-x86_64-2.zip";
    sha1 = "e75d6188f943fbca5d97696411f07f8084107777";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-win32-x86_64-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-win32-x86_64-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-win32-x86_64-3.zip";
    sha1 = "043b3e23308d9650807d33aa8555710cbd50917b";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x11-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "draw-x11-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-x11-x86_64-linux-natipkg.zip";
    sha1 = "5b56c84e4e2f50c2dac6aec4f291553a47331774";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x86_64-linux-natipkg-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-x86_64-linux-natipkg-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/009066a20290d442a38544e89d336cb3f586cfe7/draw-x86_64-linux-natipkg-2.zip";
    sha1 = "009066a20290d442a38544e89d336cb3f586cfe7";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x86_64-linux-natipkg-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-x86_64-linux-natipkg-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-x86_64-linux-natipkg-3.zip";
    sha1 = "f00234bff19d0d1703d5ae1c173d17897383785d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "draw-x86_64-macosx";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/d597bdcb7982a6d6bc39fb421ce95f11dff009e1/draw-x86_64-macosx.zip";
    sha1 = "d597bdcb7982a6d6bc39fb421ce95f11dff009e1";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x86_64-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "draw-x86_64-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/0a291e1f09fcb5a8f5ceab19e996fb85231a7493/draw-x86_64-macosx-2.zip";
    sha1 = "0a291e1f09fcb5a8f5ceab19e996fb85231a7493";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x86_64-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-x86_64-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/draw-x86_64-macosx-3.zip";
    sha1 = "8e8186eb802bc415e4776a7b41ae6e4326f5435b";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drbayes" = self.lib.mkRacketDerivation rec {
  pname = "drbayes";
  src = fetchgit {
    name = "drbayes";
    url = "git://github.com/ntoronto/drbayes.git";
    rev = "e59eb7c7867118bf4c77ca903e133c7530e612a3";
    sha256 = "1b9rzs42vsclppg23iw1x1s28l0558ai3v48gs6sh6mqzgzhdfkk";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."math-lib" self."images-lib" self."plot-gui-lib" self."plot-lib" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete";
  src = self.lib.extractPath {
    path = "drcomplete";
    src = fetchgit {
    name = "drcomplete";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."drcomplete-filename" self."drcomplete-required" self."drcomplete-user-defined" self."drcomplete-module" self."drcomplete-auto" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-auto" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-auto";
  src = self.lib.extractPath {
    path = "drcomplete-auto";
    src = fetchgit {
    name = "drcomplete-auto";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."drracket-plugin-lib" self."drracket" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-base" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-base";
  src = self.lib.extractPath {
    path = "drcomplete-base";
    src = fetchgit {
    name = "drcomplete-base";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-filename" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-filename";
  src = self.lib.extractPath {
    path = "drcomplete-filename";
    src = fetchgit {
    name = "drcomplete-filename";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."srfi-lib" self."drcomplete-base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-module" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-module";
  src = self.lib.extractPath {
    path = "drcomplete-module";
    src = fetchgit {
    name = "drcomplete-module";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."drcomplete-base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-required" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-required";
  src = self.lib.extractPath {
    path = "drcomplete-required";
    src = fetchgit {
    name = "drcomplete-required";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."srfi-lib" self."drcomplete-base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-user-defined" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-user-defined";
  src = self.lib.extractPath {
    path = "drcomplete-user-defined";
    src = fetchgit {
    name = "drcomplete-user-defined";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "b0ec0b1958c3f7fdf51a932117a684af7adaf56e";
    sha256 = "098yny8ch75fr6k3krcma2xszkbmpjgj4b712py7cd2ffy0py7b9";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."syntax-color-lib" self."drcomplete-base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drdr" = self.lib.mkRacketDerivation rec {
  pname = "drdr";
  src = fetchgit {
    name = "drdr";
    url = "git://github.com/racket/drdr.git";
    rev = "e5aa926a552151a814bdb45c69d8fd1b6b51b3cc";
    sha256 = "0wi1gk912c732kclzc5q0wznlsd40hw2gaza7qa61klf50gcadag";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."net-lib" self."web-server-lib" self."web-server-test" self."job-queue-lib" self."at-exp-lib" self."scheme-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drdr2" = self.lib.mkRacketDerivation rec {
  pname = "drdr2";
  src = fetchgit {
    name = "drdr2";
    url = "git://github.com/racket/drdr2.git";
    rev = "680818e5cfa7d48de02bf1a027f78d766498a48d";
    sha256 = "00m92fzii3vbb97n2k1jyw2ih2hcjkszdp0gilipknr7c5j5wqz1";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."sandbox-lib" self."eli-tester" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dropbox" = self.lib.mkRacketDerivation rec {
  pname = "dropbox";
  src = fetchgit {
    name = "dropbox";
    url = "git://github.com/stchang/dropbox.git";
    rev = "fc978c6c2feca00a74c4e5f9f7213a55585abe68";
    sha256 = "00bms50mivzllnm9xhqq9sn4zqmbz0pxl4ny2i14s0vbxd7zazsb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket" = self.lib.mkRacketDerivation rec {
  pname = "drracket";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket.zip";
    sha1 = "4ad62420ae8812ddb66f07620b427b53a2544434";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."data-lib" self."compiler-lib" self."base" self."planet-lib" self."compatibility-lib" self."draw-lib" self."errortrace-lib" self."macro-debugger-text-lib" self."parser-tools-lib" self."pconvert-lib" self."pict-lib" self."profile-lib" self."sandbox-lib" self."scribble-lib" self."snip-lib" self."string-constants-lib" self."typed-racket-lib" self."wxme-lib" self."gui-lib" self."racket-index" self."html-lib" self."images-lib" self."icons" self."typed-racket-more" self."net-lib" self."tex-table" self."htdp-lib" self."drracket-plugin-lib" self."gui-pkg-manager-lib" self."drracket-tool-lib" self."pict-snip-lib" self."option-contract-lib" self."syntax-color-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-ayu-mirage" = self.lib.mkRacketDerivation rec {
  pname = "drracket-ayu-mirage";
  src = fetchgit {
    name = "drracket-ayu-mirage";
    url = "git://github.com/oransimhony/drracket-ayu-mirage.git";
    rev = "5271740c3f0089e3958647353c24b73a3a80e401";
    sha256 = "0jb8lv4dcby3mq8xv2vsigjs0q4jnb7gv35ihi8l0760nqzvfn60";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-cyberpunk" = self.lib.mkRacketDerivation rec {
  pname = "drracket-cyberpunk";
  src = fetchgit {
    name = "drracket-cyberpunk";
    url = "git://github.com/thinkmoore/drracket-cyberpunk.git";
    rev = "65d2ccc304b2f1d81423f78f9330a314497f8aae";
    sha256 = "0flywlzswx5fpd5rgd3ys0rzv43nvpp6ym47js11spidvamkzzq5";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-material" = self.lib.mkRacketDerivation rec {
  pname = "drracket-material";
  src = fetchgit {
    name = "drracket-material";
    url = "git://github.com/turbinenreiter/drracket-material.git";
    rev = "560b77fffe55bfc06b3cce6416cbbdda759dd16f";
    sha256 = "011kwkz1dhszjzi15s56cxdzjyngj5j2hmym4gyqxx6dmqf0wjgj";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-paredit" = self.lib.mkRacketDerivation rec {
  pname = "drracket-paredit";
  src = fetchgit {
    name = "drracket-paredit";
    url = "git://github.com/yjqww6/drracket-paredit.git";
    rev = "fd33f286788a22425b3cc1ba3a22d93227697aef";
    sha256 = "0h5kcxkm17dh04ixzzxrwg61kpdm7c03f56fzvdcxa6i15zy8fjg";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."srfi-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-plugin-lib" = self.lib.mkRacketDerivation rec {
  pname = "drracket-plugin-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-plugin-lib.zip";
    sha1 = "4b2f97969fff66f021beff3f7130fbba95fda759";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-scheme-dark-green" = self.lib.mkRacketDerivation rec {
  pname = "drracket-scheme-dark-green";
  src = fetchgit {
    name = "drracket-scheme-dark-green";
    url = "git://github.com/shhyou/drracket-scheme-dark-green.git";
    rev = "035a9089cdfd1472a506476b70a0c3f6e3fd5664";
    sha256 = "1aqlcjdxff2237z2pg3hnwk5681qyxkmg21x84mn0azjq9nxrbia";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-solarized" = self.lib.mkRacketDerivation rec {
  pname = "drracket-solarized";
  src = fetchgit {
    name = "drracket-solarized";
    url = "git://github.com/takikawa/drracket-solarized.git";
    rev = "9a90657bb320d4231c85dff96ceaef6a835c5c4f";
    sha256 = "177xjmgkm5c3pzzfnj2lxl0d7xdpnziiw6knbns5ip7wfr21ajvf";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-test" = self.lib.mkRacketDerivation rec {
  pname = "drracket-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-test.zip";
    sha1 = "a6a2bf231357d8db8ec53330c3a62d565af27bf8";
  };
  racketThinBuildInputs = [ self."base" self."htdp" self."drracket" self."racket-index" self."scheme-lib" self."at-exp-lib" self."rackunit-lib" self."compatibility-lib" self."gui-lib" self."htdp" self."compiler-lib" self."cext-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-tool.zip";
    sha1 = "4b5c89a249efb42b56e2b6aff10257a97976c666";
  };
  racketThinBuildInputs = [ self."drracket-tool-lib" self."drracket-tool-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-doc" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-tool-doc.zip";
    sha1 = "16f359c5a764cf09758cc1c21fe41264659bc250";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."drracket-tool-lib" self."gui-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-lib" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-tool-lib.zip";
    sha1 = "819b4003f6d5979dd3d572f16144cc3ef31dda30";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."string-constants-lib" self."scribble-lib" self."racket-index" self."gui-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-test" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/drracket-tool-test.zip";
    sha1 = "c94a717a6e33a7e831caf3b79ac64b8ab94b0cf4";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."drracket-tool-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-vim-tool" = self.lib.mkRacketDerivation rec {
  pname = "drracket-vim-tool";
  src = fetchgit {
    name = "drracket-vim-tool";
    url = "git://github.com/takikawa/drracket-vim-tool.git";
    rev = "c347e8f8dcb0d89efd44755587b108e1f420912a";
    sha256 = "1lmr870iikzis1x38cl7g4dibzm1j0bs2ab3hwln65dx4j4z4vcx";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."data-lib" self."drracket-plugin-lib" self."rackunit-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-zenburn" = self.lib.mkRacketDerivation rec {
  pname = "drracket-zenburn";
  src = fetchgit {
    name = "drracket-zenburn";
    url = "git://github.com/tautologico/drracket-zenburn.git";
    rev = "baec7d09cf9dad88303f123d30626fc466b32c81";
    sha256 = "02916zapsydi13hv2p4bz1j817gqmvnd5v92xynzcv3wwz4c6qxz";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ds-store" = self.lib.mkRacketDerivation rec {
  pname = "ds-store";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/ds-store.zip";
    sha1 = "b3bd45fa30da36c8bc4ac3256da342447a2b4a9c";
  };
  racketThinBuildInputs = [ self."ds-store-lib" self."ds-store-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ds-store-doc" = self.lib.mkRacketDerivation rec {
  pname = "ds-store-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/ds-store-doc.zip";
    sha1 = "60e8de58bbfadbf94aba0abffb5b1eed849de687";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."ds-store-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ds-store-lib" = self.lib.mkRacketDerivation rec {
  pname = "ds-store-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/ds-store-lib.zip";
    sha1 = "41ccf308d3e673cb003bb38b93287d8864da9f8d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dset" = self.lib.mkRacketDerivation rec {
  pname = "dset";
  src = fetchgit {
    name = "dset";
    url = "git://github.com/pnwamk/dset.git";
    rev = "ce3581c73c42a3c8bbb6b4498325109fdf221c12";
    sha256 = "0cvkn9yl7r54dhdcqr88ywkjnr6p6jkgzyc44apdc8n9wkj5g69k";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dssl" = self.lib.mkRacketDerivation rec {
  pname = "dssl";
  src = fetchgit {
    name = "dssl";
    url = "git://github.com/tov/dssl.git";
    rev = "bb5040d0a608a3b6f7f16d6ae725b24388f6aa6c";
    sha256 = "0pchqm7w9pqsymjbm8cz0yrc7pd9vlmz6qdzfrscdsym425rycwj";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."scribble-lib" self."racket-doc" self."htdp-doc" self."at-exp-lib" self."sandbox-lib" self."compatibility-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dssl2" = self.lib.mkRacketDerivation rec {
  pname = "dssl2";
  src = fetchgit {
    name = "dssl2";
    url = "git://github.com/tov/dssl2.git";
    rev = "3517a3a00d187e023cb5553aa1180571bd02b64f";
    sha256 = "0cwb6v4rnhfachdywlzvcb5q4n44fs35azdx4nahsp5jl0zns1k4";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."rackunit-lib" self."parser-tools-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dynamic-ffi" = self.lib.mkRacketDerivation rec {
  pname = "dynamic-ffi";
  src = fetchgit {
    name = "dynamic-ffi";
    url = "git://github.com/dbenoit17/dynamic-ffi.git";
    rev = "a1ab6473c8911226bd97fffa19b31c0bc641ca12";
    sha256 = "1nh3qyadw8bcra91wylkyw3m4by7ih1kfa8jyqgpgmb6z2pl3say";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."rackunit-lib" self."at-exp-lib" self."scribble-lib" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dynamic-xml" = self.lib.mkRacketDerivation rec {
  pname = "dynamic-xml";
  src = fetchgit {
    name = "dynamic-xml";
    url = "git://github.com/zyrolasting/dynamic-xml.git";
    rev = "0e41c5b26fd0780604d0ecdc27d1e2c40faceb97";
    sha256 = "0pqv3psvr3wkakbpaasqiwz5b6ha49yppibipswcf9740k026aia";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dynext-lib" = self.lib.mkRacketDerivation rec {
  pname = "dynext-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/dynext-lib.zip";
    sha1 = "89cd5cd941d07f30dee9d76e987984b163e3ad58";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ebml" = self.lib.mkRacketDerivation rec {
  pname = "ebml";
  src = fetchgit {
    name = "ebml";
    url = "git://github.com/jbclements/ebml.git";
    rev = "2ec0b537cf88dfbcf791f28a3ecd45583ff6295a";
    sha256 = "0928gyblpg34gwvlr0115j0g8rxs7qz5hy8ga59p2rmxyyp41gjs";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "echonest" = self.lib.mkRacketDerivation rec {
  pname = "echonest";
  src = fetchgit {
    name = "echonest";
    url = "git://github.com/greghendershott/echonest.git";
    rev = "fd7d6511231bb4304cfd10260825e86ac33c3ddc";
    sha256 = "0z4sh1gna22ab4jpwv3p4xmhrbchpiik3314pg9mzhddq4jlq2nr";
  };
  racketThinBuildInputs = [ self."base" self."wffi" self."rackjure" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ecmascript" = self.lib.mkRacketDerivation rec {
  pname = "ecmascript";
  src = fetchgit {
    name = "ecmascript";
    url = "git://github.com/lwhjp/ecmascript.git";
    rev = "69fcfa42856ea799ff9d9d63a60eaf1b1783fe50";
    sha256 = "0ppy9a8x9ljf28ha5idkm12fdzw4rss532vxc0a6sq2vzy62pl81";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."parser-tools-lib" self."ragg" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ee-lib" = self.lib.mkRacketDerivation rec {
  pname = "ee-lib";
  src = fetchgit {
    name = "ee-lib";
    url = "git://github.com/michaelballantyne/ee-lib.git";
    rev = "15175289009f568369cf84a7953c3be30fa1ba2a";
    sha256 = "0hnw4hay33in8zf4k7phybnpm504qf1d6l22rjfighlgdcxgh1b3";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "effection" = self.lib.mkRacketDerivation rec {
  pname = "effection";
  src = self.lib.extractPath {
    path = "effection";
    src = fetchgit {
    name = "effection";
    url = "git://github.com/rocketnia/effection.git";
    rev = "b47d6981456b2293dff5b32db388b47007d15a8e";
    sha256 = "1dn65lynfyh45lc2pp1vp6lv5cn54wdfw6s9m38ghl071mqayfhm";
  };
  };
  racketThinBuildInputs = [ self."effection-doc" self."effection-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "effection-doc" = self.lib.mkRacketDerivation rec {
  pname = "effection-doc";
  src = self.lib.extractPath {
    path = "effection-doc";
    src = fetchgit {
    name = "effection-doc";
    url = "git://github.com/rocketnia/effection.git";
    rev = "b47d6981456b2293dff5b32db388b47007d15a8e";
    sha256 = "1dn65lynfyh45lc2pp1vp6lv5cn54wdfw6s9m38ghl071mqayfhm";
  };
  };
  racketThinBuildInputs = [ self."base" self."parendown-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "effection-lib" = self.lib.mkRacketDerivation rec {
  pname = "effection-lib";
  src = self.lib.extractPath {
    path = "effection-lib";
    src = fetchgit {
    name = "effection-lib";
    url = "git://github.com/rocketnia/effection.git";
    rev = "b47d6981456b2293dff5b32db388b47007d15a8e";
    sha256 = "1dn65lynfyh45lc2pp1vp6lv5cn54wdfw6s9m38ghl071mqayfhm";
  };
  };
  racketThinBuildInputs = [ self."base" self."interconfection-lib" self."lathe-comforts-lib" self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "effection-test" = self.lib.mkRacketDerivation rec {
  pname = "effection-test";
  src = self.lib.extractPath {
    path = "effection-test";
    src = fetchgit {
    name = "effection-test";
    url = "git://github.com/rocketnia/effection.git";
    rev = "b47d6981456b2293dff5b32db388b47007d15a8e";
    sha256 = "1dn65lynfyh45lc2pp1vp6lv5cn54wdfw6s9m38ghl071mqayfhm";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "effects" = self.lib.mkRacketDerivation rec {
  pname = "effects";
  src = fetchgit {
    name = "effects";
    url = "git://github.com/tonyg/racket-effects.git";
    rev = "e4e7cd99e120660b84baa6c7612995a528e8a1b2";
    sha256 = "122ziar6g2z35bkf72jfkg1w3938dzwwgcrwjcca6hiby9dvrzkl";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "egal" = self.lib.mkRacketDerivation rec {
  pname = "egal";
  src = fetchgit {
    name = "egal";
    url = "git://github.com/samth/egal.git";
    rev = "ea395262430ee0c5dffc264a92b0ad4d1a1a9bc8";
    sha256 = "0127zhyd4wjh3flpz6qs1wjifxqcqkrh79c57h6w6yaw9ihrqx7s";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "egg-herbie-linux" = self.lib.mkRacketDerivation rec {
  pname = "egg-herbie-linux";
  src = fetchgit {
    name = "egg-herbie-linux";
    url = "git://github.com/herbie-fp/egg-herbie.git";
    rev = "092178475f4293824544704b1bda2a9fdd6cc897";
    sha256 = "00y9l4an3pa1dhlbl2k4z2814413p0zz8xbhp1w7jjcpcr33hhw0";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "egg-herbie-osx" = self.lib.mkRacketDerivation rec {
  pname = "egg-herbie-osx";
  src = fetchgit {
    name = "egg-herbie-osx";
    url = "git://github.com/herbie-fp/egg-herbie.git";
    rev = "ec75310de6da23fd9da8a2e37a83926e668d8133";
    sha256 = "196yq9glkn19n63bzbsrbr7xfz4q16pfds33w3sy5g6s5prsxqab";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "egg-herbie-windows" = self.lib.mkRacketDerivation rec {
  pname = "egg-herbie-windows";
  src = fetchgit {
    name = "egg-herbie-windows";
    url = "git://github.com/herbie-fp/egg-herbie.git";
    rev = "fccab080c71715ebe88be52868e54250b133939b";
    sha256 = "1sj8mmfwv98iykffxhnvn4rnlb7vrv3qm1zinq42c5in241k78wq";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ejs" = self.lib.mkRacketDerivation rec {
  pname = "ejs";
  src = fetchgit {
    name = "ejs";
    url = "git://github.com/jessealama/ejs.git";
    rev = "6b8e74c48e98e1db0a02ddfe72eb44be9070112f";
    sha256 = "1w1jw7npf7p1aw7g3n57akisd50fwh7fjmzql61za2mvxyjrr185";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ekans" = self.lib.mkRacketDerivation rec {
  pname = "ekans";
  src = fetchgit {
    name = "ekans";
    url = "git://github.com/kalxd/ekans.git";
    rev = "12819d45dcafa30291ef7207f7160255a3c6805c";
    sha256 = "0hdnmp60c4ii4cda7pi3l6bhqaac09dzv55ras1q7lgsf5psv4j6";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "elasticsearch" = self.lib.mkRacketDerivation rec {
  pname = "elasticsearch";
  src = fetchgit {
    name = "elasticsearch";
    url = "git://github.com/vishesh/elasticsearch.rkt.git";
    rev = "160e2be024a21e7b043b93a5d45eaaca8e3713a1";
    sha256 = "118qldmcjhxr7vfi12lhswqj37gadwan8h2rh9wdxshwavy4wksp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "elf" = self.lib.mkRacketDerivation rec {
  pname = "elf";
  src = fetchurl {
    url = "http://code_man.cybnet.ch/racket/elf.zip";
    sha1 = "b4ce29f51fa06b6c283e5acf348f318dec539b16";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "eli-tester" = self.lib.mkRacketDerivation rec {
  pname = "eli-tester";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/eli-tester.zip";
    sha1 = "1fc10123bce1e4a5ffe746005104ddc1d8c92969";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "emcsabac" = self.lib.mkRacketDerivation rec {
  pname = "emcsabac";
  src = fetchgit {
    name = "emcsabac";
    url = "git://github.com/tnelson/emcsabac.git";
    rev = "e14172de583770ebfae544cc40432738e429a4dc";
    sha256 = "1hjh0fvqlpz3bp5xzljbsnr3y07pvcnwc1347ksp7cyj8nq5wn7i";
  };
  racketThinBuildInputs = [ self."base" self."rosette" self."ocelot" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "emoji" = self.lib.mkRacketDerivation rec {
  pname = "emoji";
  src = self.lib.extractPath {
    path = "emoji";
    src = fetchgit {
    name = "emoji";
    url = "git://github.com/whichxjy/emoji.git";
    rev = "f1a1bececc0f6ed232bc3f77f1975818b457d9f8";
    sha256 = "1z837mdi86b5mnhq9facdd2hqvg8lrzccjmis8hj0zkxmipfgl7z";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "english" = self.lib.mkRacketDerivation rec {
  pname = "english";
  src = fetchgit {
    name = "english";
    url = "git://github.com/thoughtstem/english.git";
    rev = "b03f3b203fdbc11780291e09a528ff0590b5802b";
    sha256 = "0g5iplx40z1sbbh2i518jzy0ghhnhrb2pwwyilrchqhipbvxv48v";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "envy" = self.lib.mkRacketDerivation rec {
  pname = "envy";
  src = fetchgit {
    name = "envy";
    url = "git://github.com/lexi-lambda/envy.git";
    rev = "0adfe762ea5ee9237ec67e15b1880a8767060ffb";
    sha256 = "0syyswjvs7k2h44kynizlwpnx49109x2vlwgm2bpbr0mnrv9ny0p";
  };
  racketThinBuildInputs = [ self."base" self."sweet-exp-lib" self."threading" self."typed-racket-lib" self."racket-doc" self."scribble-lib" self."sweet-exp" self."typed-racket-doc" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "eopl" = self.lib.mkRacketDerivation rec {
  pname = "eopl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/eopl.zip";
    sha1 = "678b3a870d1656d36e6189edebb52ebef67805ff";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace" = self.lib.mkRacketDerivation rec {
  pname = "errortrace";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/errortrace.zip";
    sha1 = "58c7a3abbe5e760252b2e8e3cb2e23cf4c99a8c7";
  };
  racketThinBuildInputs = [ self."errortrace-lib" self."errortrace-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-doc" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/errortrace-doc.zip";
    sha1 = "a6aedd3dc8f8d4782bec2fb02e2881f6616b97c4";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."errortrace-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-lib" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/errortrace-lib.zip";
    sha1 = "db4cddd98ef81ad32d958d999696a6432c508829";
  };
  racketThinBuildInputs = [ self."base" self."source-syntax" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-test" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/errortrace-test.zip";
    sha1 = "260663f31386bc8896c8c26fc1ffad2de6bce78e";
  };
  racketThinBuildInputs = [ self."errortrace-lib" self."eli-tester" self."rackunit-lib" self."base" self."compiler-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "esc-vp21" = self.lib.mkRacketDerivation rec {
  pname = "esc-vp21";
  src = fetchgit {
    name = "esc-vp21";
    url = "git://github.com/mordae/racket-esc-vp21.git";
    rev = "01bc89268f4f051d55885f64d4a0fac671a762b9";
    sha256 = "062rlx7qhzgsb12jc5pkgc6rjr31h0warwplk5pr5pl7c0s3xkd3";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."mordae" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "event-lang" = self.lib.mkRacketDerivation rec {
  pname = "event-lang";
  src = fetchgit {
    name = "event-lang";
    url = "git://github.com/dedbox/racket-event-lang.git";
    rev = "5c31cb32a816b0b23af2905bf25c7c3b69bd36cb";
    sha256 = "1nyyylzrfg38n4an07j4570ics5ky4cggg4xq4xscq48j5dddagm";
  };
  racketThinBuildInputs = [ self."algebraic" self."base" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "eventfd" = self.lib.mkRacketDerivation rec {
  pname = "eventfd";
  src = fetchgit {
    name = "eventfd";
    url = "git://github.com/mordae/racket-eventfd.git";
    rev = "f4e8e36525ca23009c71bc9838181cdba5503c98";
    sha256 = "13l3pbigj8pivb8x9m786qkyjbjjvlcr864ch6nx7yb7l5c5lwr1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "exact-decimal-lang" = self.lib.mkRacketDerivation rec {
  pname = "exact-decimal-lang";
  src = fetchgit {
    name = "exact-decimal-lang";
    url = "git://github.com/AlexKnauth/exact-decimal-lang.git";
    rev = "0aae96ff741748e3a7da4239ad748e56c5f49470";
    sha256 = "0f6v4rps9nx9qlxnwrnygjchk23myji41bh3rbcz6rmx3c9qvg0v";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."scribble-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "expander" = self.lib.mkRacketDerivation rec {
  pname = "expander";
  src = self.lib.extractPath {
    path = "racket/src/expander";
    src = fetchgit {
    name = "expander";
    url = "git://github.com/racket/racket.git";
    rev = "d590eee0c773af8a1c530db244f0f1ddb29e7871";
    sha256 = "0pnkvhc6kb4493fhw4ajw1mqln8c5467k5kmcplbw4dm4nwchd60";
  };
  };
  racketThinBuildInputs = [ self."base" self."zo-lib" self."compiler-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "expect" = self.lib.mkRacketDerivation rec {
  pname = "expect";
  src = fetchgit {
    name = "expect";
    url = "git://github.com/jackfirth/racket-expect.git";
    rev = "9530df30537ae05400b6a3add9619e5f697dca52";
    sha256 = "144sa4i069sg428kij5y3zivk9njaw3my89v5aaz1yhdlirlgapp";
  };
  racketThinBuildInputs = [ self."syntax-classes-lib" self."arguments" self."base" self."fancy-app" self."rackunit-lib" self."reprovide-lang" self."rackunit-doc" self."doc-coverage" self."racket-doc" self."scribble-lib" self."scribble-text-lib" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "explorer" = self.lib.mkRacketDerivation rec {
  pname = "explorer";
  src = fetchgit {
    name = "explorer";
    url = "git://github.com/tonyg/racket-explorer.git";
    rev = "2a1836d01a7ff2ed025a67cc5f06c38b56776b2d";
    sha256 = "0ml68mrxhl002vi7zm6gpqv740r54gjgi51fvj8vqajnqmbc24vf";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "expr-in-racket" = self.lib.mkRacketDerivation rec {
  pname = "expr-in-racket";
  src = fetchgit {
    name = "expr-in-racket";
    url = "git://github.com/connor2059/expr-in-racket.git";
    rev = "fa8266d311df18010da4e56648e06a9fe53c6b0b";
    sha256 = "1x8fmy6a9hwbpd4gxpic3cy2ywnh1kw4xamfqlksmv5blzfhzdsa";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "extensible-functions" = self.lib.mkRacketDerivation rec {
  pname = "extensible-functions";
  src = fetchgit {
    name = "extensible-functions";
    url = "git://github.com/leafac/extensible-functions.git";
    rev = "7aa4c134ba48137bd66d30ad9282d261a5507dbe";
    sha256 = "0pafm182lh8pdx3ha7bfb7vz9i69wh19dg0pck4c3pyqc2pzjf1s";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "extensible-parser-specifications" = self.lib.mkRacketDerivation rec {
  pname = "extensible-parser-specifications";
  src = fetchgit {
    name = "extensible-parser-specifications";
    url = "git://github.com/jsmaniac/extensible-parser-specifications.git";
    rev = "0204fd4f47902c1545ccbfee764dd2c161456258";
    sha256 = "13pbp3p0ax6c0ivzglmry3d2klp3z4293c0v0q5k7rsb80349xxj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."phc-toolkit" self."generic-syntax-expanders" self."alexis-util" self."scribble-lib" self."racket-doc" self."seq-no-order" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fairyfloss" = self.lib.mkRacketDerivation rec {
  pname = "fairyfloss";
  src = fetchgit {
    name = "fairyfloss";
    url = "git://github.com/HeladoDeBrownie/DrRacket-Theme-fairyfloss.git";
    rev = "967a9db447145f56e178273e930067d36c4668b5";
    sha256 = "03z6mxrswi0pwcw4z21bijgxcf8g36lrfalsgx3y7a758whihnhb";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fancy-app" = self.lib.mkRacketDerivation rec {
  pname = "fancy-app";
  src = fetchgit {
    name = "fancy-app";
    url = "git://github.com/samth/fancy-app.git";
    rev = "39a132ff500f2cb3d23f5b9907af2409193a7b96";
    sha256 = "1hyqvhvg6yns044rd1xlja75ha7czbvfyh82dnw49dky28ls29d1";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fast-convert" = self.lib.mkRacketDerivation rec {
  pname = "fast-convert";
  src = fetchgit {
    name = "fast-convert";
    url = "git://github.com/Kalimehtar/fast-convert.git";
    rev = "2420aeb2ce8c7fb3e14d0ee1d560c33e16aa1b80";
    sha256 = "1rnfvnm91r4pn099097k1hw70sjydh9jcmsjmfp2i2yakjzh4hgw";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "faster-minikanren" = self.lib.mkRacketDerivation rec {
  pname = "faster-minikanren";
  src = fetchgit {
    name = "faster-minikanren";
    url = "git://github.com/michaelballantyne/faster-miniKanren.git";
    rev = "a2a4a80cebbdd4845a3b800aefc292956071b70c";
    sha256 = "00d4nvddrqq1frnbjfbw897394nvs82f0d364fq09r45as23ymsv";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "feature-profile" = self.lib.mkRacketDerivation rec {
  pname = "feature-profile";
  src = fetchgit {
    name = "feature-profile";
    url = "git://github.com/stamourv/feature-profile";
    rev = "cc96e3aa8efe71c013f662c60e2b0d9231b27f97";
    sha256 = "0yymgv192qfpy6smynk3xafzf9j95hjvhgg1h7gxnd3r4wg6hw91";
  };
  racketThinBuildInputs = [ self."base" self."contract-profile" self."profile-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fector" = self.lib.mkRacketDerivation rec {
  pname = "fector";
  src = fetchgit {
    name = "fector";
    url = "git://github.com/dvanhorn/fector.git";
    rev = "269812d67549fbd77273f5025a4144214d790081";
    sha256 = "0v07ignzw06dmx2fzdi8rkz92z51ynlbmvd1j3dgjpyxlgzjg5g9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffi-definer-convention" = self.lib.mkRacketDerivation rec {
  pname = "ffi-definer-convention";
  src = fetchgit {
    name = "ffi-definer-convention";
    url = "git://github.com/takikawa/racket-ffi-definer-convention.git";
    rev = "5b6a361adeb1f079b9fabc80055ce592152a9d9a";
    sha256 = "0076lrl9hmdnmy0n0yn1dk6kriwv46lmi0vr0ljsm4kz6s4c9lz3";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffi-utils" = self.lib.mkRacketDerivation rec {
  pname = "ffi-utils";
  src = fetchgit {
    name = "ffi-utils";
    url = "git://github.com/thinkmoore/ffi-utils.git";
    rev = "20fd038aad7978f6613a78cc48fae1358b90089d";
    sha256 = "1g1v39s9czwb0qhjpxm00ssx1rw3dk0r6wbd7gkcd08sysxl07lx";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-i386-win32" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-i386-win32";
  src = self.lib.extractPath {
    path = "ffmpeg-i386-win32";
    src = fetchgit {
    name = "ffmpeg-i386-win32";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-i386-win32-3-4" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-i386-win32-3-4";
  src = self.lib.extractPath {
    path = "ffmpeg-i386-win32";
    src = fetchgit {
    name = "ffmpeg-i386-win32-3-4";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "e8fb290d38e90800ffa1d105dbb540d28f931807";
    sha256 = "1h5nrhdlb9z89vx4irrzxcpc7zgpyjk1vy6yc598yfq1hskmwjvl";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-x86_64-macosx";
  src = self.lib.extractPath {
    path = "ffmpeg-x86_64-macosx";
    src = fetchgit {
    name = "ffmpeg-x86_64-macosx";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-x86_64-macosx-3-4" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-x86_64-macosx-3-4";
  src = self.lib.extractPath {
    path = "ffmpeg-x86_64-macosx";
    src = fetchgit {
    name = "ffmpeg-x86_64-macosx-3-4";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "e8fb290d38e90800ffa1d105dbb540d28f931807";
    sha256 = "1h5nrhdlb9z89vx4irrzxcpc7zgpyjk1vy6yc598yfq1hskmwjvl";
  };
  };
  racketThinBuildInputs = [ self."base" self."openh264-x86_64-macosx" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-x86_64-win32" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-x86_64-win32";
  src = self.lib.extractPath {
    path = "ffmpeg-x86_64-win32";
    src = fetchgit {
    name = "ffmpeg-x86_64-win32";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ffmpeg-x86_64-win32-3-4" = self.lib.mkRacketDerivation rec {
  pname = "ffmpeg-x86_64-win32-3-4";
  src = self.lib.extractPath {
    path = "ffmpeg-x86_64-win32";
    src = fetchgit {
    name = "ffmpeg-x86_64-win32-3-4";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "e8fb290d38e90800ffa1d105dbb540d28f931807";
    sha256 = "1h5nrhdlb9z89vx4irrzxcpc7zgpyjk1vy6yc598yfq1hskmwjvl";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fiberweb" = self.lib.mkRacketDerivation rec {
  pname = "fiberweb";
  src = fetchgit {
    name = "fiberweb";
    url = "git://github.com/jackfirth/fiberweb.git";
    rev = "e8136d1ed7e746d0dd90fd9264f7d62d90472990";
    sha256 = "0fmkhlnpk829c7bw411x7d2zdcgrrhr8dzn9cjl7qw4ap6ljzw76";
  };
  racketThinBuildInputs = [ self."base" self."rebellion" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "file-metadata" = self.lib.mkRacketDerivation rec {
  pname = "file-metadata";
  src = fetchgit {
    name = "file-metadata";
    url = "git://github.com/dstorrs/file-metadata.git";
    rev = "d8f90fdd911e0e97b754cb74d5963f2c3c465637";
    sha256 = "15rr8x1a6j0vi05lqazwch8fwxmh4k5k45c4zkdlamcg6lhd1qar";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "file-watchers" = self.lib.mkRacketDerivation rec {
  pname = "file-watchers";
  src = fetchgit {
    name = "file-watchers";
    url = "git://github.com/zyrolasting/file-watchers.git";
    rev = "54cc3401f419f64b9334484ae401e20f05f2a3d5";
    sha256 = "0q56da72qz9glh9hmgfds37x5niwxicakl75y4ddyvdlx4ia8ihl";
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "files-viewer" = self.lib.mkRacketDerivation rec {
  pname = "files-viewer";
  src = fetchgit {
    name = "files-viewer";
    url = "git://github.com/MatrixForChange/files-viewer.git";
    rev = "495109dcc97ff34e0377ae7a4a45074bb2cde15b";
    sha256 = "0k1l6p9zycnbcasnq6vb2wqcf7lijksrhhyp7na607zzsfpkxazr";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."drracket" self."rackunit-lib" self."scheme-lib" self."compatibility-lib" self."scribble-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "finalizer" = self.lib.mkRacketDerivation rec {
  pname = "finalizer";
  src = fetchgit {
    name = "finalizer";
    url = "git://github.com/Kalimehtar/finalizer.git";
    rev = "74517770d70b786a3df48fd20ea9ea8059e4a641";
    sha256 = "0330q6n7s1zvszh3x8x47njhdm1v7l3kamwnsrgplp6hjchl4i5w";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "find-parent-dir" = self.lib.mkRacketDerivation rec {
  pname = "find-parent-dir";
  src = fetchgit {
    name = "find-parent-dir";
    url = "git://github.com/samth/find-parent-dir.git";
    rev = "e78d0277447d81934847166e8024edc5adea4b1c";
    sha256 = "0h2ssvpc6iz1aw4j1lqcw7rdy2rjxm78rdq8gvap9m8vr0vsak2x";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fixture" = self.lib.mkRacketDerivation rec {
  pname = "fixture";
  src = fetchgit {
    name = "fixture";
    url = "git://github.com/jackfirth/racket-fixture.git";
    rev = "fafde5528ad6491cd9e87c078f9838eabc524a87";
    sha256 = "0mwf1wp4v2w1l0k4q6c5hqajrch37aypn2rbfymwc6zfmgw3ikld";
  };
  racketThinBuildInputs = [ self."reprovide-lang" self."fancy-app" self."rackunit-lib" self."base" self."disposable" self."doc-coverage" self."racket-doc" self."rackunit-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "flexpr" = self.lib.mkRacketDerivation rec {
  pname = "flexpr";
  src = fetchgit {
    name = "flexpr";
    url = "git://github.com/greghendershott/flexpr.git";
    rev = "a547ca94094a2090f12b0028b634da0b08d42df8";
    sha256 = "09iv9ghib5afsh38ivc6av998pl9avdsbpww0l8m1875zcsaf006";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fme" = self.lib.mkRacketDerivation rec {
  pname = "fme";
  src = fetchgit {
    name = "fme";
    url = "git://github.com/pnwamk/fme";
    rev = "63075d432e7803b2822a78568306c29a6fde557c";
    sha256 = "09yf25ffg893845ri79if6gqdpzbipvkvxl58gbdgg408y75f7bi";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "font-finder" = self.lib.mkRacketDerivation rec {
  pname = "font-finder";
  src = fetchgit {
    name = "font-finder";
    url = "git://github.com/dstorrs/font-finder.git";
    rev = "fa316eef64ee8525ad741479f132246b4a0acf85";
    sha256 = "1d0wzss0wr2wid0gfpbx50g1b662y2gpgq1ny0n9m1jyfls5kpbr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fontconfig" = self.lib.mkRacketDerivation rec {
  pname = "fontconfig";
  src = fetchgit {
    name = "fontconfig";
    url = "git://github.com/takikawa/racket-fontconfig.git";
    rev = "3c4332aa72fff0ddf1172d442f30954dffde616b";
    sha256 = "18z534l74zip2gmkin1m3s15ps981hwsykmwz4mqmkagqlgy346d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fontland" = self.lib.mkRacketDerivation rec {
  pname = "fontland";
  src = fetchgit {
    name = "fontland";
    url = "git://github.com/mbutterick/fontland.git";
    rev = "059ef832d0a55c1b13c4556927bfee99f54c83ae";
    sha256 = "1q314inn5d1ihxj13djf7adbaiysnwdqdw9swizmw20yd3lhyjs1";
  };
  racketThinBuildInputs = [ self."crc32c" self."db-lib" self."base" self."beautiful-racket-lib" self."debug" self."draw-lib" self."rackunit-lib" self."png-image" self."sugar" self."xenomorph" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forge" = self.lib.mkRacketDerivation rec {
  pname = "forge";
  src = self.lib.extractPath {
    path = "forge";
    src = fetchgit {
    name = "forge";
    url = "git://github.com/cemcutting/Forge.git";
    rev = "c3d94b5eae69eb4c648a3eed0079421592acd3eb";
    sha256 = "0vlrgbpjdajp592awh4haq51k3c9iwg78hhnjwq03c30y1sizfis";
  };
  };
  racketThinBuildInputs = [ self."beautiful-racket" self."predicates" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forged-ocelot" = self.lib.mkRacketDerivation rec {
  pname = "forged-ocelot";
  src = fetchgit {
    name = "forged-ocelot";
    url = "git://github.com/cemcutting/forged-ocelot.git";
    rev = "f28a7012348b9096ede5cb1da64ef6544686b205";
    sha256 = "182x10c1fxbrzdczsi119s3vpdy3c6arcfx4f72kk42k9xyjx53b";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."sandbox-lib" self."rosette" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forms" = self.lib.mkRacketDerivation rec {
  pname = "forms";
  src = self.lib.extractPath {
    path = "forms";
    src = fetchgit {
    name = "forms";
    url = "git://github.com/Bogdanp/racket-forms.git";
    rev = "2898792ffe546eb50f85f7f54f17638cc2194d9c";
    sha256 = "1vpzmn89rb2znh3kia5zwbgkxcqb6jljny8mh62kw6nv6gxpyqrc";
  };
  };
  racketThinBuildInputs = [ self."forms-doc" self."forms-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forms-doc" = self.lib.mkRacketDerivation rec {
  pname = "forms-doc";
  src = self.lib.extractPath {
    path = "forms-doc";
    src = fetchgit {
    name = "forms-doc";
    url = "git://github.com/Bogdanp/racket-forms.git";
    rev = "2898792ffe546eb50f85f7f54f17638cc2194d9c";
    sha256 = "1vpzmn89rb2znh3kia5zwbgkxcqb6jljny8mh62kw6nv6gxpyqrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."forms-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."web-server-doc" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forms-lib" = self.lib.mkRacketDerivation rec {
  pname = "forms-lib";
  src = self.lib.extractPath {
    path = "forms-lib";
    src = fetchgit {
    name = "forms-lib";
    url = "git://github.com/Bogdanp/racket-forms.git";
    rev = "2898792ffe546eb50f85f7f54f17638cc2194d9c";
    sha256 = "1vpzmn89rb2znh3kia5zwbgkxcqb6jljny8mh62kw6nv6gxpyqrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."srfi-lite-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forms-test" = self.lib.mkRacketDerivation rec {
  pname = "forms-test";
  src = self.lib.extractPath {
    path = "forms-test";
    src = fetchgit {
    name = "forms-test";
    url = "git://github.com/Bogdanp/racket-forms.git";
    rev = "2898792ffe546eb50f85f7f54f17638cc2194d9c";
    sha256 = "1vpzmn89rb2znh3kia5zwbgkxcqb6jljny8mh62kw6nv6gxpyqrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."forms-lib" self."rackunit-lib" self."srfi-lite-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forth" = self.lib.mkRacketDerivation rec {
  pname = "forth";
  src = fetchgit {
    name = "forth";
    url = "git://github.com/bennn/forth.git";
    rev = "fe84d4200ba2b038888153b649b872b55f7aebea";
    sha256 = "16qqbs3xqfvr7j5kl1ib5hz72zhc6yi6mpsd83nssr201pjw97a5";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."rackunit-abbrevs" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fpbench" = self.lib.mkRacketDerivation rec {
  pname = "fpbench";
  src = fetchgit {
    name = "fpbench";
    url = "git://github.com/FPBench/FPBench.git";
    rev = "eec3c553d00c3a4dc9c6bd4a5815dce117cd4979";
    sha256 = "0iwbq3ggg6m4s0blg5d0hl35sy4m54qcyal25s7jaf4ass29ppb9";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fra" = self.lib.mkRacketDerivation rec {
  pname = "fra";
  src = fetchgit {
    name = "fra";
    url = "git://github.com/jeapostrophe/fra.git";
    rev = "151ca5afbb8e732e0da89198cf0b982625233b87";
    sha256 = "0zrsmy70xab1m6m5x36pd6yaq9ifxyxcn7ih75c2m80a3j045wrk";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fragments" = self.lib.mkRacketDerivation rec {
  pname = "fragments";
  src = fetchgit {
    name = "fragments";
    url = "git://github.com/srfoster/fragments.git";
    rev = "1041f29a85313deed3ab55bc6a69418b9239a1fd";
    sha256 = "048602d0wf2l8hbnhnwpnx2mjbg5v13i2j7kxyz4975azlcnb78d";
  };
  racketThinBuildInputs = [ self."base" self."simple-http" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fragments-first" = self.lib.mkRacketDerivation rec {
  pname = "fragments-first";
  src = fetchgit {
    name = "fragments-first";
    url = "git://github.com/srfoster/fragments-first.git";
    rev = "f9a6bec8a8ec537874d04c05c2a6d27b0af11e38";
    sha256 = "07nk2gbk9mjn01j1998mnkzsz5n1akyir4avymmmbk3qknn39haf";
  };
  racketThinBuildInputs = [ self."base" self."fragments" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "frog" = self.lib.mkRacketDerivation rec {
  pname = "frog";
  src = fetchgit {
    name = "frog";
    url = "git://github.com/greghendershott/frog.git";
    rev = "b5597abee813a1b2feb714ab4154759790b58586";
    sha256 = "1l0f7cm629ba1bcx4mg8baldiiz20h3r84i07aanfzxx10jyjwhb";
  };
  racketThinBuildInputs = [ self."base" self."find-parent-dir" self."html-lib" self."markdown" self."racket-index" self."reprovide-lang" self."scribble-lib" self."scribble-text-lib" self."srfi-lite-lib" self."threading-lib" self."web-server-lib" self."at-exp-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."scribble-text-lib" self."threading-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "frtime" = self.lib.mkRacketDerivation rec {
  pname = "frtime";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/frtime.zip";
    sha1 = "7e8af92888f838f17cb5768a30f4a020d883d15f";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."compatibility-lib" self."drracket" self."gui-lib" self."pict-lib" self."string-constants-lib" self."draw-doc" self."gui-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ftree" = self.lib.mkRacketDerivation rec {
  pname = "ftree";
  src = fetchgit {
    name = "ftree";
    url = "git://github.com/stchang/ftree.git";
    rev = "4f5f57c437446b83a01bb251659dc0cfdbd88167";
    sha256 = "0cnir6vxjfiy5b0l2sawsvy4lz5yk2z7vap60c1czl4ajrbmznj0";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fulmar" = self.lib.mkRacketDerivation rec {
  pname = "fulmar";
  src = fetchgit {
    name = "fulmar";
    url = "git://github.com/cwearl/fulmar.git";
    rev = "4cf60699558b3bb28fa813443456993d1563bfb2";
    sha256 = "04gfs1gi1gj2ya01f32a2r3m9fy4f1vpf0bx4lq9h4f9p2w847s1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."rackunit-lib" self."sandbox-lib" self."at-exp-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "functional" = self.lib.mkRacketDerivation rec {
  pname = "functional";
  src = self.lib.extractPath {
    path = "functional";
    src = fetchgit {
    name = "functional";
    url = "git://github.com/lexi-lambda/functional.git";
    rev = "d42bad2669ff5aaa07879a9797fcc42ce7dd9df4";
    sha256 = "09020dhrwlqa4xdf8jbp7vmzfgnahn3q3dif1z48cff59fwdvyrb";
  };
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" self."functional-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "functional-doc" = self.lib.mkRacketDerivation rec {
  pname = "functional-doc";
  src = self.lib.extractPath {
    path = "functional-doc";
    src = fetchgit {
    name = "functional-doc";
    url = "git://github.com/lexi-lambda/functional.git";
    rev = "d42bad2669ff5aaa07879a9797fcc42ce7dd9df4";
    sha256 = "09020dhrwlqa4xdf8jbp7vmzfgnahn3q3dif1z48cff59fwdvyrb";
  };
  };
  racketThinBuildInputs = [ self."collections-doc+functional-doc" self."base" self."collections-lib" self."functional-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [ "functional-doc" "collections-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "functional-lib" = self.lib.mkRacketDerivation rec {
  pname = "functional-lib";
  src = self.lib.extractPath {
    path = "functional-lib";
    src = fetchgit {
    name = "functional-lib";
    url = "git://github.com/lexi-lambda/functional.git";
    rev = "d42bad2669ff5aaa07879a9797fcc42ce7dd9df4";
    sha256 = "09020dhrwlqa4xdf8jbp7vmzfgnahn3q3dif1z48cff59fwdvyrb";
  };
  };
  racketThinBuildInputs = [ self."collections-lib+functional-lib" self."base" self."curly-fn-lib" self."static-rename" ];
  circularBuildInputs = [ "collections-lib" "functional-lib" ];
  reverseCircularBuildInputs = [  ];
  };
  "fuse" = self.lib.mkRacketDerivation rec {
  pname = "fuse";
  src = fetchgit {
    name = "fuse";
    url = "git://github.com/thinkmoore/racket-fuse.git";
    rev = "5c24b1e135e97ff6c8e49b363f01ff21c28ecf8b";
    sha256 = "0ajzd1cf79asa6s7p4yzzrwkl6n0v8lpzvxvssm5lw7lymwrb01s";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."base" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "future-visualizer" = self.lib.mkRacketDerivation rec {
  pname = "future-visualizer";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/future-visualizer.zip";
    sha1 = "b07c479e5ba1309617590be16c3a0580b06ef138";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."data-lib" self."draw-lib" self."pict-lib" self."gui-lib" self."scheme-lib" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "future-visualizer-typed" = self.lib.mkRacketDerivation rec {
  pname = "future-visualizer-typed";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/future-visualizer-typed.zip";
    sha1 = "30304e8c9e0e7ffa00c1a9b45154786a4707fa3b";
  };
  racketThinBuildInputs = [ self."base" self."future-visualizer" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "futures-sort" = self.lib.mkRacketDerivation rec {
  pname = "futures-sort";
  src = fetchgit {
    name = "futures-sort";
    url = "git://github.com/dzoep/futures-sort.git";
    rev = "dc1914f60b192897855989d4b87846eaa95aa777";
    sha256 = "0v5v51kmcy0lhp6nfg7s5qdisl1v575rz6na142aid616h6s401v";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."scribble-math" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fuzzy-search" = self.lib.mkRacketDerivation rec {
  pname = "fuzzy-search";
  src = fetchgit {
    name = "fuzzy-search";
    url = "git://github.com/zyrolasting/fuzzy-search.git";
    rev = "8a55ab77a1c2e2d835c782dff25fbb7d8732fa34";
    sha256 = "15vys4ny4sy4p3gr6xymv21dhcfvsycnp3jq2lhxpdhjmll34m23";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "g-code-tools" = self.lib.mkRacketDerivation rec {
  pname = "g-code-tools";
  src = fetchgit {
    name = "g-code-tools";
    url = "git://github.com/GThad/g-code-tools.git";
    rev = "8a786ec0608afdc0729c344e7cd58d368fc86ff9";
    sha256 = "08p1dlbikrpqgklgg3m1xrjvhvgb3n0q41s5lpsn7735li1qy951";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "games" = self.lib.mkRacketDerivation rec {
  pname = "games";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/games.zip";
    sha1 = "056516afff97359d836240f4ee1ea8bd95e3081d";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."drracket" self."gui-lib" self."net-lib" self."htdp-lib" self."math-lib" self."scribble-lib" self."racket-index" self."sgl" self."srfi-lib" self."string-constants-lib" self."data-enumerate-lib" self."typed-racket-lib" self."typed-racket-more" self."draw-doc" self."gui-doc" self."racket-doc" self."pict-lib" self."rackunit-lib" self."htdp-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gcstats" = self.lib.mkRacketDerivation rec {
  pname = "gcstats";
  src = fetchgit {
    name = "gcstats";
    url = "git://github.com/samth/gcstats.git";
    rev = "c1112a07155f2a8e8a8ad999c9980d544d56b970";
    sha256 = "071xmsf7zdkp20bfyld793sfi17a4wk43aibx3i545yv52wv5s4m";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gdbdump" = self.lib.mkRacketDerivation rec {
  pname = "gdbdump";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/gdbdump.zip";
    sha1 = "34e26cb2f32b78ca2804684f587caa9102b7593e";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."compatibility-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gen-queue-lib" = self.lib.mkRacketDerivation rec {
  pname = "gen-queue-lib";
  src = self.lib.extractPath {
    path = "gen-queue-lib";
    src = fetchgit {
    name = "gen-queue-lib";
    url = "git://github.com/stchang/graph.git";
    rev = "ba621328a26803c72a0d3890aaa5ac81c166f117";
    sha256 = "1jg01r0p9hx2ylhc349fsc71amcvikhnx4x5pahsvxjm73jvvkrk";
  };
  };
  racketThinBuildInputs = [ self."base" self."data-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "generator-util" = self.lib.mkRacketDerivation rec {
  pname = "generator-util";
  src = fetchgit {
    name = "generator-util";
    url = "git://github.com/countvajhula/generator-util.git";
    rev = "3026d9009c9c22047d2fa73ee395d624a1fc5463";
    sha256 = "1g6qmm7rs8bkls8sxx2g7rfjx2f9gc5xcfpgjq487jmvnlhx204w";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."Relation" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."collections-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "generic-bind" = self.lib.mkRacketDerivation rec {
  pname = "generic-bind";
  src = fetchgit {
    name = "generic-bind";
    url = "git://github.com/stchang/generic-bind.git";
    rev = "77e6dd7c87bd1e9ee9bd083a1c47d400ad79c6d1";
    sha256 = "1mb9xg573hv0bcjz9rm557057iw1dv2z2pxv2bgddwzn7xfnl3s4";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."math-lib" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "generic-syntax-expanders" = self.lib.mkRacketDerivation rec {
  pname = "generic-syntax-expanders";
  src = fetchgit {
    name = "generic-syntax-expanders";
    url = "git://github.com/jackfirth/generic-syntax-expanders.git";
    rev = "6d3b41875095d0f18d6e1d88bf7a8ed3981fe999";
    sha256 = "048gdsgwdmzi9060r46af08y89g7z5kqn1kx89s32pgyb0w5jkmc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."fancy-app" self."reprovide-lang" self."lens" self."point-free" self."predicates" self."scribble-lib" self."scribble-text-lib" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "geoip" = self.lib.mkRacketDerivation rec {
  pname = "geoip";
  src = self.lib.extractPath {
    path = "geoip";
    src = fetchgit {
    name = "geoip";
    url = "git://github.com/Bogdanp/racket-geoip.git";
    rev = "6b3597c626443ce191145f90df2fb64f1b8b9ac7";
    sha256 = "0chyrch7p41gj53sj9hld4fs2wx9mbiyf327kkfr934zy56s1x7n";
  };
  };
  racketThinBuildInputs = [ self."geoip-doc" self."geoip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "geoip-doc" = self.lib.mkRacketDerivation rec {
  pname = "geoip-doc";
  src = self.lib.extractPath {
    path = "geoip-doc";
    src = fetchgit {
    name = "geoip-doc";
    url = "git://github.com/Bogdanp/racket-geoip.git";
    rev = "6b3597c626443ce191145f90df2fb64f1b8b9ac7";
    sha256 = "0chyrch7p41gj53sj9hld4fs2wx9mbiyf327kkfr934zy56s1x7n";
  };
  };
  racketThinBuildInputs = [ self."base" self."geoip-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "geoip-lib" = self.lib.mkRacketDerivation rec {
  pname = "geoip-lib";
  src = self.lib.extractPath {
    path = "geoip-lib";
    src = fetchgit {
    name = "geoip-lib";
    url = "git://github.com/Bogdanp/racket-geoip.git";
    rev = "6b3597c626443ce191145f90df2fb64f1b8b9ac7";
    sha256 = "0chyrch7p41gj53sj9hld4fs2wx9mbiyf327kkfr934zy56s1x7n";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-ip-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "get-bonus" = self.lib.mkRacketDerivation rec {
  pname = "get-bonus";
  src = fetchgit {
    name = "get-bonus";
    url = "git://github.com/get-bonus/get-bonus.git";
    rev = "08d304c0300cb7dc2f98b90413d69a314bc781a1";
    sha256 = "0g3y9h2adj48v3fgyli50fwa0c7fif938pmi9nh21ls8kx5yzcgp";
  };
  racketThinBuildInputs = [ self."3s" self."openal" self."lux" self."dos" self."fector" self."opengl" self."base" self."compatibility-lib" self."data-lib" self."data-enumerate-lib" self."draw-lib" self."eli-tester" self."gui-lib" self."htdp-lib" self."math" self."pfds" self."plot" self."rackunit-lib" self."redex-lib" self."mode-lambda" self."apse" self."slideshow-lib" self."typed-racket-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "get-pass" = self.lib.mkRacketDerivation rec {
  pname = "get-pass";
  src = fetchgit {
    name = "get-pass";
    url = "git://github.com/smitchell556/get-pass.git";
    rev = "897434c1f6bcad997e85909aacd82a7c8d33c691";
    sha256 = "04ri0n5priksv7hz9r0c8i7wvw8f79x37x0lwqzccp73jz1vhkx5";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "get-primitive" = self.lib.mkRacketDerivation rec {
  pname = "get-primitive";
  src = fetchgit {
    name = "get-primitive";
    url = "git://github.com/samth/get-primitive.git";
    rev = "c69044511178cd544f5ce0c3d672c1e077030282";
    sha256 = "0h7azv5xj6zm96n775ry7vvlahbzn58z86dabgi72x0ym70lkm7p";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gettext" = self.lib.mkRacketDerivation rec {
  pname = "gettext";
  src = fetchgit {
    name = "gettext";
    url = "git://github.com/Kalimehtar/free-gettext.git";
    rev = "fd00d769a9cce03bb8675ee62299c878b9c0d5bb";
    sha256 = "01pxjizlvag18yadiy2c6ik72n732rixbzy0awibwwzpnmxnm678";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gir" = self.lib.mkRacketDerivation rec {
  pname = "gir";
  src = fetchgit {
    name = "gir";
    url = "git://github.com/Kalimehtar/gir.git";
    rev = "668b693a4e0148ae5305493a3c7440e35f155082";
    sha256 = "10gkpyih51ridx31qqxc5qll112ljj491g4wcl3ybmchzc10c7il";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "git-slice" = self.lib.mkRacketDerivation rec {
  pname = "git-slice";
  src = fetchgit {
    name = "git-slice";
    url = "git://github.com/samth/git-slice.git";
    rev = "110b361425280e61abf8de99e5d41865afc5cddb";
    sha256 = "04q3p0x9kk9mh1a34wh0sq7y18c0vqrj8c8zhdgc6rmpbibz9hh2";
  };
  racketThinBuildInputs = [ self."base" self."remote-shell" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "github" = self.lib.mkRacketDerivation rec {
  pname = "github";
  src = fetchgit {
    name = "github";
    url = "git://github.com/samth/github.rkt.git";
    rev = "3dcabdece43c6f46050966a51ad237c75032cd17";
    sha256 = "0q02npjxcs5n1kv5dmn3h6y6f2sx2mbf60w2s43hxkr25m7jngy7";
  };
  racketThinBuildInputs = [ self."base" self."drracket-plugin-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "github-api" = self.lib.mkRacketDerivation rec {
  pname = "github-api";
  src = fetchgit {
    name = "github-api";
    url = "git://github.com/eu90h/racket-github-api.git";
    rev = "2079df4a8a61d6f71722d9e7eb0aff4043995018";
    sha256 = "14qmi06kfgkhrjf5sqwk7bz6nwbc7prad2jssd9xk99ssgrib006";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glfw3" = self.lib.mkRacketDerivation rec {
  pname = "glfw3";
  src = fetchgit {
    name = "glfw3";
    url = "git://github.com/BourgondAries/rkt-glfw.git";
    rev = "e52613f60f25aeac7f035b1f11a79401a770af35";
    sha256 = "0lny8zbfyd8598r42ilkkhqgafplpzzi7g2aji2b56mvq5vzpvhn";
  };
  racketThinBuildInputs = [ self."base" self."disposable" self."fixture" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glm" = self.lib.mkRacketDerivation rec {
  pname = "glm";
  src = fetchgit {
    name = "glm";
    url = "git://github.com/dedbox/racket-glm.git";
    rev = "9ab93fe8549f6ce8da29ce651a175bf35a4d996d";
    sha256 = "10f7s7z05ahvpq42dx3n2m2ir8sas2vza941na3papg005kwrz4f";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glob" = self.lib.mkRacketDerivation rec {
  pname = "glob";
  src = fetchgit {
    name = "glob";
    url = "git://github.com/bennn/glob.git";
    rev = "92e261a05d074d7021980bfbe3060f3fa9008686";
    sha256 = "1pk2bfaaclaha1z52m311ny9a5gcw6b5nph5y7cdcily6amj7ajf";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glossolalia" = self.lib.mkRacketDerivation rec {
  pname = "glossolalia";
  src = fetchgit {
    name = "glossolalia";
    url = "git://github.com/robertkleffner/glossolalia.git";
    rev = "2f7d6c2865267aaee4709ca6640243b89ecf6c6d";
    sha256 = "0wvhb68gssk2w76y2dnybhhfqzw0c7fby37l824hjfw141zg08xk";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."math-lib" self."brag" self."beautiful-racket" self."beautiful-racket-lib" self."br-parser-tools-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gls" = self.lib.mkRacketDerivation rec {
  pname = "gls";
  src = fetchgit {
    name = "gls";
    url = "git://github.com/Kalimehtar/gls.git";
    rev = "82f2f504a3ccf534126020baedb406f813863143";
    sha256 = "174cqg4b8hsybz4pikygn2lj29ggp0clx1vndk5w858cdsjzz73x";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lite-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glsl" = self.lib.mkRacketDerivation rec {
  pname = "glsl";
  src = fetchgit {
    name = "glsl";
    url = "git://github.com/dedbox/racket-glsl.git";
    rev = "6853bcb4324a10deb2cec70e59fb8b401a45e9f3";
    sha256 = "069wd47g37rn7hj7saxaxpkygk9d51r854p2s5nvvy3pli2fwzxz";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glu-tessellate" = self.lib.mkRacketDerivation rec {
  pname = "glu-tessellate";
  src = fetchgit {
    name = "glu-tessellate";
    url = "git://github.com/mflatt/glu-tessellate.git";
    rev = "8efe65b35a2554be6dc613c016791ef2bf5ffb82";
    sha256 = "0dpnvzg4zqkwd8lvxw0fxarph6fswmbl02gycjxwcw8vs3aymm3g";
  };
  racketThinBuildInputs = [ self."base" self."draw-doc" self."gui-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gm-pepm-2018" = self.lib.mkRacketDerivation rec {
  pname = "gm-pepm-2018";
  src = self.lib.extractPath {
    path = "gm-pepm-2018";
    src = fetchgit {
    name = "gm-pepm-2018";
    url = "git://github.com/nuprl/retic_performance.git";
    rev = "621211c2f40251ce5364c33e72e4067e34a32013";
    sha256 = "1jsapgmpmqx35fbb2gk623qdpf9ymmbj76p4q92bghrbf9w1a11h";
  };
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."html-parsing" self."math-lib" self."pict-lib" self."plot-lib" self."scribble-lib" self."slideshow-lib" self."sxml" self."with-cache" self."pict-doc" self."racket-doc" self."rackunit-abbrevs" self."rackunit-lib" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gmp" = self.lib.mkRacketDerivation rec {
  pname = "gmp";
  src = self.lib.extractPath {
    path = "gmp";
    src = fetchgit {
    name = "gmp";
    url = "git://github.com/rmculpepper/racket-gmp.git";
    rev = "c20c2b4c7564382cf3ab262dbfbe8b1dbaa63c17";
    sha256 = "0n9wcysmgr17j7y6mwx0jvlzgx763d213bppxql7x1nrnfzc5n68";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."binaryio-lib" self."gmp-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gmp-lib" = self.lib.mkRacketDerivation rec {
  pname = "gmp-lib";
  src = self.lib.extractPath {
    path = "gmp-lib";
    src = fetchgit {
    name = "gmp-lib";
    url = "git://github.com/rmculpepper/racket-gmp.git";
    rev = "c20c2b4c7564382cf3ab262dbfbe8b1dbaa63c17";
    sha256 = "0n9wcysmgr17j7y6mwx0jvlzgx763d213bppxql7x1nrnfzc5n68";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gnal-lang" = self.lib.mkRacketDerivation rec {
  pname = "gnal-lang";
  src = fetchgit {
    name = "gnal-lang";
    url = "git://github.com/AlexKnauth/gnal-lang.git";
    rev = "9ce8615c21ae6e9768d2e5c88609466492a4ac80";
    sha256 = "1i5w5r29v3xw9y58kv97k90wixzw2zlzbb9p20h8krg735vgw7yd";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gnucash" = self.lib.mkRacketDerivation rec {
  pname = "gnucash";
  src = fetchgit {
    name = "gnucash";
    url = "git://github.com/jbclements/gnucash.git";
    rev = "4b8c74104c7aa0ceb93357a6b7985364dd34a192";
    sha256 = "0znkhpxm846y2xfla2rjfjjm4sv4b7i84wfxr62r9wkpq1ldcnpq";
  };
  racketThinBuildInputs = [ self."base" self."sxml" self."srfi-lib" self."srfi-lite-lib" self."memoize" self."rackunit-lib" self."typed-racket-lib" self."rackunit-typed" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "goblins" = self.lib.mkRacketDerivation rec {
  pname = "goblins";
  src = self.lib.extractPath {
    path = "goblins";
    src = fetchgit {
    name = "goblins";
    url = "https://gitlab.com/spritely/goblins.git";
    rev = "b836e11aa820c7ea43100d18ce71cbf53c9e47cd";
    sha256 = "1726x67sknmw9bmwb7kbsy0qfyniakw94l4r8l34mw7lmkw8as7a";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto" self."rackunit-lib" self."scribble-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "google" = self.lib.mkRacketDerivation rec {
  pname = "google";
  src = fetchgit {
    name = "google";
    url = "git://github.com/tonyg/racket-google.git";
    rev = "236b1fb8bdd0975bf2ce820f6277927c7bc25635";
    sha256 = "0s7mp9jg7fjr3kz2r9kmalv2jq333c2h7hq403kpa7xsfdqk2pbr";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."net-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "google-spreadsheet-api" = self.lib.mkRacketDerivation rec {
  pname = "google-spreadsheet-api";
  src = fetchgit {
    name = "google-spreadsheet-api";
    url = "https://gitlab.com/car.margiotta/google-spreadsheet-api.git";
    rev = "081c8a9543b5d1f0a5329de62c87eec5f12e8b9c";
    sha256 = "1vb2vh8s8w6i1y0ky7qv1crdnrq83f5xsb8v6mglcbsm2aqci3na";
  };
  racketThinBuildInputs = [ self."base" self."crypto" self."net-jwt" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."scribble-code-examples" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gradual-typing-bib" = self.lib.mkRacketDerivation rec {
  pname = "gradual-typing-bib";
  src = fetchgit {
    name = "gradual-typing-bib";
    url = "git://github.com/samth/gradual-typing-bib.git";
    rev = "de11b548af5c917897b67e339a3cd9c394dcf1f3";
    sha256 = "0w5lh205yyaf6pqaydam0w1csabmg4jvr3qa6hzl47p3y1ppp5zw";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graph" = self.lib.mkRacketDerivation rec {
  pname = "graph";
  src = self.lib.extractPath {
    path = "graph";
    src = fetchgit {
    name = "graph";
    url = "git://github.com/stchang/graph.git";
    rev = "ba621328a26803c72a0d3890aaa5ac81c166f117";
    sha256 = "1jg01r0p9hx2ylhc349fsc71amcvikhnx4x5pahsvxjm73jvvkrk";
  };
  };
  racketThinBuildInputs = [ self."base" self."graph-lib" self."graph-doc" self."graph-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graph-doc" = self.lib.mkRacketDerivation rec {
  pname = "graph-doc";
  src = self.lib.extractPath {
    path = "graph-doc";
    src = fetchgit {
    name = "graph-doc";
    url = "git://github.com/stchang/graph.git";
    rev = "ba621328a26803c72a0d3890aaa5ac81c166f117";
    sha256 = "1jg01r0p9hx2ylhc349fsc71amcvikhnx4x5pahsvxjm73jvvkrk";
  };
  };
  racketThinBuildInputs = [ self."base" self."graph-lib" self."racket-doc" self."math-doc" self."math-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graph-lib" = self.lib.mkRacketDerivation rec {
  pname = "graph-lib";
  src = self.lib.extractPath {
    path = "graph-lib";
    src = fetchgit {
    name = "graph-lib";
    url = "git://github.com/stchang/graph.git";
    rev = "ba621328a26803c72a0d3890aaa5ac81c166f117";
    sha256 = "1jg01r0p9hx2ylhc349fsc71amcvikhnx4x5pahsvxjm73jvvkrk";
  };
  };
  racketThinBuildInputs = [ self."base" self."gen-queue-lib" self."data-lib" self."math-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graph-test" = self.lib.mkRacketDerivation rec {
  pname = "graph-test";
  src = self.lib.extractPath {
    path = "graph-test";
    src = fetchgit {
    name = "graph-test";
    url = "git://github.com/stchang/graph.git";
    rev = "ba621328a26803c72a0d3890aaa5ac81c166f117";
    sha256 = "1jg01r0p9hx2ylhc349fsc71amcvikhnx4x5pahsvxjm73jvvkrk";
  };
  };
  racketThinBuildInputs = [ self."base" self."graph-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graphics" = self.lib.mkRacketDerivation rec {
  pname = "graphics";
  src = fetchgit {
    name = "graphics";
    url = "git://github.com/wargrey/graphics.git";
    rev = "83b51572e60577f957adafe03532727feeb6de3a";
    sha256 = "05p2dhj8pg0sprgk7vxf0abqzf7gc57n04slkiycpawwq1bjwdb8";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."draw-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graphics-engine" = self.lib.mkRacketDerivation rec {
  pname = "graphics-engine";
  src = fetchgit {
    name = "graphics-engine";
    url = "git://github.com/dedbox/racket-graphics-engine.git";
    rev = "94d492f057e1fa712ceab1823afca31ffc80f04d";
    sha256 = "0sbwkc142x9ws8zvyfkylpb9nnzkfmqryjx9ma1xv7jfjsk4pzr6";
  };
  racketThinBuildInputs = [ self."base" self."opengl" self."glm" self."glsl" self."gui-lib" self."reprovide-lang-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gregor" = self.lib.mkRacketDerivation rec {
  pname = "gregor";
  src = self.lib.extractPath {
    path = "gregor";
    src = fetchgit {
    name = "gregor";
    url = "git://github.com/97jaz/gregor.git";
    rev = "76f1c593f475e9847d25f9d014d41289f16d3393";
    sha256 = "0sbavcv5aixvf2gbi5ywn8ils7v4h7rhm11imzssv8g43ciwviqn";
  };
  };
  racketThinBuildInputs = [ self."gregor-lib" self."gregor-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gregor-doc" = self.lib.mkRacketDerivation rec {
  pname = "gregor-doc";
  src = self.lib.extractPath {
    path = "gregor-doc";
    src = fetchgit {
    name = "gregor-doc";
    url = "git://github.com/97jaz/gregor.git";
    rev = "76f1c593f475e9847d25f9d014d41289f16d3393";
    sha256 = "0sbavcv5aixvf2gbi5ywn8ils7v4h7rhm11imzssv8g43ciwviqn";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."racket-doc" self."data-doc" self."data-lib" self."gregor-lib" self."scribble-lib" self."sandbox-lib" self."tzinfo" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gregor-lib" = self.lib.mkRacketDerivation rec {
  pname = "gregor-lib";
  src = self.lib.extractPath {
    path = "gregor-lib";
    src = fetchgit {
    name = "gregor-lib";
    url = "git://github.com/97jaz/gregor.git";
    rev = "76f1c593f475e9847d25f9d014d41289f16d3393";
    sha256 = "0sbavcv5aixvf2gbi5ywn8ils7v4h7rhm11imzssv8g43ciwviqn";
  };
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."memoize" self."parser-tools-lib" self."tzinfo" self."cldr-core" self."cldr-bcp47" self."cldr-numbers-modern" self."cldr-dates-modern" self."cldr-localenames-modern" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gregor-test" = self.lib.mkRacketDerivation rec {
  pname = "gregor-test";
  src = self.lib.extractPath {
    path = "gregor-test";
    src = fetchgit {
    name = "gregor-test";
    url = "git://github.com/97jaz/gregor.git";
    rev = "76f1c593f475e9847d25f9d014d41289f16d3393";
    sha256 = "0sbavcv5aixvf2gbi5ywn8ils7v4h7rhm11imzssv8g43ciwviqn";
  };
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "grift" = self.lib.mkRacketDerivation rec {
  pname = "grift";
  src = fetchgit {
    name = "grift";
    url = "git://github.com/Gradual-Typing/Grift.git";
    rev = "e812fdd40e3f47c78a2bc850274ebc0f7fd040d4";
    sha256 = "1gs407y13ynbiwwahbyg10c0gghfzg6l52i8xww52821qm1p17x0";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gsl-integration" = self.lib.mkRacketDerivation rec {
  pname = "gsl-integration";
  src = fetchgit {
    name = "gsl-integration";
    url = "git://github.com/petterpripp/gsl-integration.git";
    rev = "90f7ba19a596f636b299530a8f378bda7b34afb8";
    sha256 = "17aqa6rnnpp4wcs64ca3jsk1py477yh5xb6pq2mhkzwyxi6absdw";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."scribble-math" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gsl-rng" = self.lib.mkRacketDerivation rec {
  pname = "gsl-rng";
  src = fetchgit {
    name = "gsl-rng";
    url = "git://github.com/petterpripp/gsl-rng.git";
    rev = "c7d98142b55ab990af8d1d27d59be17058755dcd";
    sha256 = "01cm22b2yv0350igajdzx3k9m6vpirmx553r2q4kw1z20vgcm4lm";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-benchmarks" = self.lib.mkRacketDerivation rec {
  pname = "gtp-benchmarks";
  src = fetchgit {
    name = "gtp-benchmarks";
    url = "git://github.com/bennn/gtp-benchmarks.git";
    rev = "4ddb425e32cc581c43d89a2e974b4a59ca2260b3";
    sha256 = "0fhkzvkcbn7s97qak78k78niq4idshld9bx3083p62fc7lh969b6";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."require-typed-check" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-doc" self."at-exp-lib" self."gtp-util" self."pict-lib" self."scribble-abbrevs" self."syntax-sloc" self."with-cache" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-checkup" = self.lib.mkRacketDerivation rec {
  pname = "gtp-checkup";
  src = fetchgit {
    name = "gtp-checkup";
    url = "git://github.com/bennn/gtp-checkup.git";
    rev = "336ec2c1b67dd178f8fe35443532b88b71f66d16";
    sha256 = "08z1lymarhiqhfq0gbwhralq336ny6h2hvi2fnb144f9wcrcy1nw";
  };
  racketThinBuildInputs = [ self."base" self."basedir" self."data-lib" self."draw-lib" self."gregor" self."gtp-util" self."math-lib" self."memoize" self."pict-lib" self."plot-lib" self."rackunit-lib" self."require-typed-check" self."sandbox-lib" self."typed-racket-lib" self."typed-racket-more" self."zo-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-doc" self."pict-abbrevs" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-measure" = self.lib.mkRacketDerivation rec {
  pname = "gtp-measure";
  src = fetchgit {
    name = "gtp-measure";
    url = "git://github.com/bennn/gtp-measure.git";
    rev = "7fc5057ee1ea08d200cd559a0f1a00ed6401ab78";
    sha256 = "12yilj89rcs4q7wvzl8kvwkakn21hkg21xkfh1abdhbhi9iihnk8";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."basedir" self."gtp-util" self."lang-file" self."scribble-lib" self."sandbox-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."basedir" self."require-typed-check" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-paper" = self.lib.mkRacketDerivation rec {
  pname = "gtp-paper";
  src = fetchgit {
    name = "gtp-paper";
    url = "git://github.com/bennn/gtp-paper.git";
    rev = "fe8ecf5bff7a89d80ad54e6f5a3a05281b65efee";
    sha256 = "1rqfg8kgla4lk791ilflvjjfrb2pad9d7h2087a5chclkq9nd9k7";
  };
  racketThinBuildInputs = [ self."base" self."scribble-abbrevs" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-pict" = self.lib.mkRacketDerivation rec {
  pname = "gtp-pict";
  src = fetchgit {
    name = "gtp-pict";
    url = "https://gitlab.com/gradual-typing-performance/gtp-pict.git";
    rev = "9d17dc9a291e135719de2309bae659dea660cf26";
    sha256 = "0lbqlyp3l6sw3cvjcqy6gb828h4x0xqfnv9r98xx2qg04g9ffk81";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."pict-lib" self."draw-lib" self."images-lib" self."pict-abbrevs" self."ppict" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."scribble-doc" self."rackunit-abbrevs" self."pict-doc" self."draw-doc" self."images-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-plot" = self.lib.mkRacketDerivation rec {
  pname = "gtp-plot";
  src = fetchgit {
    name = "gtp-plot";
    url = "git://github.com/bennn/gtp-plot.git";
    rev = "5b9255a91e7f24bc3f542cff783f3f970404715d";
    sha256 = "085c48s4xli6sszj9xqzm8g6lq9zwfc46djsj0ls5mr4zmq0xcy1";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."scribble-abbrevs" self."scribble-lib" self."math-lib" self."pict-lib" self."plot-lib" self."reprovide-lang" self."gtp-util" self."lang-file" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."pict-lib" self."pict-doc" self."plot-doc" self."rackunit-abbrevs" self."typed-racket-doc" self."gtp-util" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-util" = self.lib.mkRacketDerivation rec {
  pname = "gtp-util";
  src = fetchgit {
    name = "gtp-util";
    url = "git://github.com/bennn/gtp-util.git";
    rev = "649d38ce7c0b851deb9beefd675d9030154f9488";
    sha256 = "0gqfbiz82bg6k3w0drln8n70fzcb5gy7nd810kgzjcbmknvayi2b";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."pict-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."scribble-doc" self."rackunit-abbrevs" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui" = self.lib.mkRacketDerivation rec {
  pname = "gui";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui.zip";
    sha1 = "dcaa07b52534b78b68f1e59ee86d5497ea8ce7ac";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."gui-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-doc" = self.lib.mkRacketDerivation rec {
  pname = "gui-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-doc.zip";
    sha1 = "746d318ce82c613f2f7cb7eb899303b510ea18ca";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."at-exp-lib" self."draw-lib" self."scribble-lib" self."snip-lib" self."string-constants-lib" self."syntax-color-lib" self."wxme-lib" self."gui-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-i386-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-i386-macosx.zip";
    sha1 = "922545e9cf7827c06462de678175dfa0a3a675f9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-lib.zip";
    sha1 = "e5d283fd6607320d15ca936ea5518cadf2166199";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."data-lib" self."icons" self."base" self."syntax-color-lib" self."draw-lib" self."snip-lib" self."wxme-lib" self."pict-lib" self."scheme-lib" self."scribble-lib" self."string-constants-lib" self."option-contract-lib" self."2d-lib" self."compatibility-lib" self."tex-table" self."gui-i386-macosx" self."gui-x86_64-macosx" self."gui-ppc-macosx" self."gui-win32-i386" self."gui-win32-x86_64" self."gui-x86_64-linux-natipkg" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-pkg-manager" = self.lib.mkRacketDerivation rec {
  pname = "gui-pkg-manager";
  src = self.lib.extractPath {
    path = "gui-pkg-manager";
    src = fetchgit {
    name = "gui-pkg-manager";
    url = "git://github.com/racket/gui-pkg-manager.git";
    rev = "54d8ebd8c58a0974334e96e257db3b038cb20135";
    sha256 = "1w72a2g2n4ng8ij0iakkcyk8wgniypd1w78xh6w5ipg563pxalqc";
  };
  };
  racketThinBuildInputs = [ self."gui-pkg-manager-lib" self."gui-pkg-manager-doc" self."gui-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-pkg-manager-doc" = self.lib.mkRacketDerivation rec {
  pname = "gui-pkg-manager-doc";
  src = self.lib.extractPath {
    path = "gui-pkg-manager-doc";
    src = fetchgit {
    name = "gui-pkg-manager-doc";
    url = "git://github.com/racket/gui-pkg-manager.git";
    rev = "54d8ebd8c58a0974334e96e257db3b038cb20135";
    sha256 = "1w72a2g2n4ng8ij0iakkcyk8wgniypd1w78xh6w5ipg563pxalqc";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-pkg-manager-lib" = self.lib.mkRacketDerivation rec {
  pname = "gui-pkg-manager-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-pkg-manager-lib.zip";
    sha1 = "54e9c6e52f552caf81fdcf1d658e00d34d9b3a1c";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-ppc-macosx.zip";
    sha1 = "2a387003d4b268a9dfe30e80a294a354c17ac630";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-test" = self.lib.mkRacketDerivation rec {
  pname = "gui-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-test.zip";
    sha1 = "941a33232ffbb15ac57d51ace4afc5b785f0cece";
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."scheme-lib" self."draw-lib" self."racket-test" self."sgl" self."snip-lib" self."wxme-lib" self."gui-lib" self."syntax-color-lib" self."rackunit-lib" self."pconvert-lib" self."compatibility-lib" self."sandbox-lib" self."pict-lib" self."pict-snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-widget-mixins" = self.lib.mkRacketDerivation rec {
  pname = "gui-widget-mixins";
  src = fetchgit {
    name = "gui-widget-mixins";
    url = "git://github.com/alex-hhh/gui-widget-mixins.git";
    rev = "12770619fd57da3e7dfdf6397fa5ade6817a252e";
    sha256 = "0dhwr75kh2hprk7x6ffxrb8gxjdqi0zlawfckfd1yidbj6cc20ml";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "gui-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-win32-i386.zip";
    sha1 = "1d3f039a4d450c36b3994ea54a791614157bafdf";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "gui-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-win32-x86_64.zip";
    sha1 = "b3f6ff40f5dc486e30fbf8449848cc7ded5663f2";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "gui-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-x86_64-linux-natipkg.zip";
    sha1 = "a5c2be644182c701c75e3ff8116c4f422ae13caa";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-x86_64-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/gui-x86_64-macosx.zip";
    sha1 = "62417646ec9360198244039396656e8599d89d72";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hackett" = self.lib.mkRacketDerivation rec {
  pname = "hackett";
  src = self.lib.extractPath {
    path = "hackett";
    src = fetchgit {
    name = "hackett";
    url = "git://github.com/lexi-lambda/hackett.git";
    rev = "8e4e0e904ac37df58b8c8ef29c0f94ad4151246f";
    sha256 = "0f1darb65qpbdr0f1r4hbbw6g1b55h9fkfhywxnsyw8z2rzc2rpq";
  };
  };
  racketThinBuildInputs = [ self."hackett-doc" self."hackett-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hackett-demo" = self.lib.mkRacketDerivation rec {
  pname = "hackett-demo";
  src = self.lib.extractPath {
    path = "hackett-demo";
    src = fetchgit {
    name = "hackett-demo";
    url = "git://github.com/lexi-lambda/hackett.git";
    rev = "8e4e0e904ac37df58b8c8ef29c0f94ad4151246f";
    sha256 = "0f1darb65qpbdr0f1r4hbbw6g1b55h9fkfhywxnsyw8z2rzc2rpq";
  };
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."hackett-lib" self."htdp-lib" self."pict-lib" self."threading-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hackett-doc" = self.lib.mkRacketDerivation rec {
  pname = "hackett-doc";
  src = self.lib.extractPath {
    path = "hackett-doc";
    src = fetchgit {
    name = "hackett-doc";
    url = "git://github.com/lexi-lambda/hackett.git";
    rev = "8e4e0e904ac37df58b8c8ef29c0f94ad4151246f";
    sha256 = "0f1darb65qpbdr0f1r4hbbw6g1b55h9fkfhywxnsyw8z2rzc2rpq";
  };
  };
  racketThinBuildInputs = [ self."base" self."hackett-lib" self."scribble-lib" self."at-exp-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hackett-lib" = self.lib.mkRacketDerivation rec {
  pname = "hackett-lib";
  src = self.lib.extractPath {
    path = "hackett-lib";
    src = fetchgit {
    name = "hackett-lib";
    url = "git://github.com/lexi-lambda/hackett.git";
    rev = "8e4e0e904ac37df58b8c8ef29c0f94ad4151246f";
    sha256 = "0f1darb65qpbdr0f1r4hbbw6g1b55h9fkfhywxnsyw8z2rzc2rpq";
  };
  };
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."data-lib" self."syntax-classes-lib" self."threading-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hackett-test" = self.lib.mkRacketDerivation rec {
  pname = "hackett-test";
  src = self.lib.extractPath {
    path = "hackett-test";
    src = fetchgit {
    name = "hackett-test";
    url = "git://github.com/lexi-lambda/hackett.git";
    rev = "8e4e0e904ac37df58b8c8ef29c0f94ad4151246f";
    sha256 = "0f1darb65qpbdr0f1r4hbbw6g1b55h9fkfhywxnsyw8z2rzc2rpq";
  };
  };
  racketThinBuildInputs = [ self."base" self."hackett-lib" self."rackunit-lib" self."sandbox-lib" self."testing-util-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "haiku-enum" = self.lib.mkRacketDerivation rec {
  pname = "haiku-enum";
  src = fetchgit {
    name = "haiku-enum";
    url = "git://github.com/rfindler/haiku-enum.git";
    rev = "6856c4c6bf3c82e30ac453cee9b57bb5ef717888";
    sha256 = "1vqifissh7rfbk3dsj70p3d3k0nsc4zvvlfksmnkwg448lkwi45c";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."math-lib" self."data-enumerate-lib" self."data-doc" self."racket-doc" self."scribble-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hamt" = self.lib.mkRacketDerivation rec {
  pname = "hamt";
  src = fetchgit {
    name = "hamt";
    url = "git://github.com/97jaz/hamt.git";
    rev = "561cb6a447e9766dcb8abf2c01b30b87d91135f5";
    sha256 = "02b1iaddimqyl58kq4l5dwnyqsgkzbfy5wg4yiky13k63ajw5gwi";
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" self."collections-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."collections-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "handin" = self.lib.mkRacketDerivation rec {
  pname = "handin";
  src = fetchgit {
    name = "handin";
    url = "git://github.com/plt/handin.git";
    rev = "cbb4523b88adb0415c2f188a96c28adf5c8fb6bf";
    sha256 = "1z934miha0riqx30aylpcx96scznp81z0rdgjqb4ddn4kiikf4cm";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."htdp-lib" self."net-lib" self."pconvert-lib" self."sandbox-lib" self."rackunit-lib" self."web-server-lib" self."gui-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "handy" = self.lib.mkRacketDerivation rec {
  pname = "handy";
  src = fetchgit {
    name = "handy";
    url = "git://github.com/dstorrs/racket-dstorrs-libs.git";
    rev = "b695136fc056e6b15d06df8af0a09e25ba6e8c6d";
    sha256 = "01v767z9npw1lxpp2f3lh77ibyd6mzkzklqdkdg75c9q5xfi3w8x";
  };
  racketThinBuildInputs = [ self."html-parsing" self."base" self."db-lib" self."rackunit-lib" self."sxml" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "happy-names" = self.lib.mkRacketDerivation rec {
  pname = "happy-names";
  src = fetchgit {
    name = "happy-names";
    url = "git://github.com/thoughtstem/happy-names.git";
    rev = "3a74d689059e77106318b751e65b113233008d19";
    sha256 = "0idx2v1s4c5nag26vwcqzk5qlnk7zf6a73zk8g774fr9cki3cbvc";
  };
  racketThinBuildInputs = [ self."memoize" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hash-lambda" = self.lib.mkRacketDerivation rec {
  pname = "hash-lambda";
  src = fetchgit {
    name = "hash-lambda";
    url = "git://github.com/AlexKnauth/hash-lambda.git";
    rev = "d65df820d1c16e4d2f8c6e1519f3a0ec838387c8";
    sha256 = "14bcj5s62mfm8j8zjmzq8r9nk7caqnk7jaqjmn1096nkijl4028v";
  };
  racketThinBuildInputs = [ self."base" self."unstable-lib" self."unstable-list-lib" self."kw-utils" self."mutable-match-lambda" self."rackunit-lib" self."at-exp-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hash-partition" = self.lib.mkRacketDerivation rec {
  pname = "hash-partition";
  src = fetchgit {
    name = "hash-partition";
    url = "git://github.com/zyrolasting/hash-partition.git";
    rev = "6f29cf061d2ae55c8564e3c3af5be3543d6cd1b9";
    sha256 = "1jgcm7ifw8l8qrs55qpcb19dqpbvpzb5nwks7a3f2zywylsb7va9";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hdf5" = self.lib.mkRacketDerivation rec {
  pname = "hdf5";
  src = fetchgit {
    name = "hdf5";
    url = "git://github.com/oetr/racket-hdf5.git";
    rev = "5836fc438ee36f94c80362b7da79b252a6429009";
    sha256 = "1kl44s3fhkyv5yf8ya69wx8yw905zskjv79k6sj97hjm8f9rls1h";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."math" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "herbie" = self.lib.mkRacketDerivation rec {
  pname = "herbie";
  src = self.lib.extractPath {
    path = "src";
    src = fetchgit {
    name = "herbie";
    url = "git://github.com/uwplse/herbie.git";
    rev = "be39213ae5627f1c994ef162f5b1721ea29d50d3";
    sha256 = "1q6ni38jwyjb30rnsnghr08plg7l26apw7qh2m3gqjyzmrhwjbyb";
  };
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."plot-lib" self."profile-lib" self."rackunit-lib" self."web-server-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "heresy" = self.lib.mkRacketDerivation rec {
  pname = "heresy";
  src = fetchgit {
    name = "heresy";
    url = "git://github.com/jarcane/heresy.git";
    rev = "a736b69178dffa2ef97f5eb5204f3e06840088c2";
    sha256 = "1c7fyj8jqpq5qgbfm0rinvsx55vjk9vdcfhcnvql8f1hxh0g8k40";
  };
  racketThinBuildInputs = [ self."base" self."unstable-lib" self."rackjure" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hidapi" = self.lib.mkRacketDerivation rec {
  pname = "hidapi";
  src = fetchgit {
    name = "hidapi";
    url = "git://github.com/jpathy/hidapi.git";
    rev = "91c5e5b8eb7380d3b6031d736e6d8fc9121a7cb0";
    sha256 = "0b310wydvw5kvjxmzd4r15ghhrbwn3hyqckbh25ys8ydjh6zwlpn";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hive-client" = self.lib.mkRacketDerivation rec {
  pname = "hive-client";
  src = fetchgit {
    name = "hive-client";
    url = "git://github.com/Kalimehtar/hive-client.git";
    rev = "5cfcb7f2c41b28610367313d35fca809994e70e5";
    sha256 = "1wa0vbjid1pk64lvafwxqhm31fgzn5bl0lnzp0ss90lggs3dv47d";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."hive-common" self."gui-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hive-common" = self.lib.mkRacketDerivation rec {
  pname = "hive-common";
  src = fetchgit {
    name = "hive-common";
    url = "git://github.com/Kalimehtar/hive-common.git";
    rev = "38d5bffacf8ddc6b8e0680997d23bf0502153bb7";
    sha256 = "1syy1r4i0740sl4zicjb6vg5blrrxbzry39s604001bhs6xcisa3";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."thread-utils" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hive-server" = self.lib.mkRacketDerivation rec {
  pname = "hive-server";
  src = fetchgit {
    name = "hive-server";
    url = "git://github.com/Kalimehtar/hive-server.git";
    rev = "f1ea7b39c94724e87de293b2264a1e1da639c41e";
    sha256 = "0b6504bbhvvkkczxbpry60iadyhnczbc6ma7q99pjqz6vl6lllmr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."hive-common" self."rackunit-lib" self."srfi-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "honu" = self.lib.mkRacketDerivation rec {
  pname = "honu";
  src = fetchgit {
    name = "honu";
    url = "git://github.com/racket/honu.git";
    rev = "b36b9aeda8be22bf7fda177e831f42ac1a1de79b";
    sha256 = "0xg9cwbkflpj8zdbkyv1jrjj3f4amcrp3kgkbl20bxq3j4r82c6y";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."macro-debugger" self."base" self."parser-tools-lib" self."rackunit-lib" self."racket-index" self."scribble-lib" self."at-exp-lib" self."sandbox-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hostname" = self.lib.mkRacketDerivation rec {
  pname = "hostname";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/hostname.zip";
    sha1 = "e235b0ed0e00388dfc80c4a20577458885679cdd";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp" = self.lib.mkRacketDerivation rec {
  pname = "htdp";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/htdp.zip";
    sha1 = "046973a0ddea349aaa31f9c43f35d4b105e96c01";
  };
  racketThinBuildInputs = [ self."htdp-lib" self."htdp-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-doc" = self.lib.mkRacketDerivation rec {
  pname = "htdp-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/htdp-doc.zip";
    sha1 = "c0ccf7932cb5d02e747331f08eb33fedc2f37fd5";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" self."draw-lib" self."gui-lib" self."htdp-lib" self."plai" self."sandbox-lib" self."pict-lib" self."mzscheme-doc" self."scheme-lib" self."compatibility-doc" self."draw-doc" self."drracket" self."gui-doc" self."pict-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-json" = self.lib.mkRacketDerivation rec {
  pname = "htdp-json";
  src = fetchgit {
    name = "htdp-json";
    url = "git://github.com/samth/htdp-json.git";
    rev = "4685de829cfc51b41b010ab0563ef24b9bcbdf5a";
    sha256 = "0rzzfpjm6pnxi95ihqgik0c6gcq9dmv5pnwx875yx1wxyrkji5m3";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."htdp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-lib" = self.lib.mkRacketDerivation rec {
  pname = "htdp-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/htdp-lib.zip";
    sha1 = "a9d2c14549f3ede318ad45c1846598f0e2d39f55";
  };
  racketThinBuildInputs = [ self."deinprogramm-signature+htdp-lib" self."base" self."compatibility-lib" self."draw-lib" self."drracket-plugin-lib" self."errortrace-lib" self."html-lib" self."images-gui-lib" self."images-lib" self."net-lib" self."pconvert-lib" self."plai-lib" self."r5rs-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."slideshow-lib" self."snip-lib" self."srfi-lite-lib" self."string-constants-lib" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."wxme-lib" self."gui-lib" self."pict-lib" self."racket-index" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "htdp-lib" "deinprogramm-signature" ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-test" = self.lib.mkRacketDerivation rec {
  pname = "htdp-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/htdp-test.zip";
    sha1 = "250fb12201e57a0cf910d23bd03607ae48300196";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."scheme-lib" self."srfi-lite-lib" self."compatibility-lib" self."gui-lib" self."racket-test" self."rackunit-lib" self."profile-lib" self."wxme-lib" self."pconvert-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html" = self.lib.mkRacketDerivation rec {
  pname = "html";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/html.zip";
    sha1 = "9c804ffca742e3f4cf04d08166679ed8fa9cc0b0";
  };
  racketThinBuildInputs = [ self."html-lib" self."html-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-doc" = self.lib.mkRacketDerivation rec {
  pname = "html-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/html-doc.zip";
    sha1 = "12ae1f63acbfa247310e1f164e56205cfb4bb555";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."html-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-lib" = self.lib.mkRacketDerivation rec {
  pname = "html-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/html-lib.zip";
    sha1 = "d14262cb09cd4463432f2113eab941edf649b282";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-parsing" = self.lib.mkRacketDerivation rec {
  pname = "html-parsing";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/html-parsing.zip";
    sha1 = "948da802f479758bbc3ddcda446c0243f1a65fe7";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-template" = self.lib.mkRacketDerivation rec {
  pname = "html-template";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/html-template.zip";
    sha1 = "9a51d5dda4dffd81cc9f3e2d7d971c808d4ad2c0";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."html-writing" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-test" = self.lib.mkRacketDerivation rec {
  pname = "html-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/html-test.zip";
    sha1 = "6a970311b93f8b30deea02c3e933f682abcaa1b7";
  };
  racketThinBuildInputs = [ self."racket-index" self."base" self."html-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-writing" = self.lib.mkRacketDerivation rec {
  pname = "html-writing";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/html-writing.zip";
    sha1 = "d0e12121d24dc7f1aebbac048bae09fa1f6507b6";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html5-lang" = self.lib.mkRacketDerivation rec {
  pname = "html5-lang";
  src = self.lib.extractPath {
    path = "html5-lang";
    src = fetchgit {
    name = "html5-lang";
    url = "git://github.com/thoughtstem/html5-lang.git";
    rev = "ae39387ef2dfd6b7df630940e1d338e854c10de8";
    sha256 = "16jv9fmz6dp2jjs6n6paygcv512710n7hc773sq3zz66562gs995";
  };
  };
  racketThinBuildInputs = [ self."hostname" self."simple-qr" self."urlang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http" = self.lib.mkRacketDerivation rec {
  pname = "http";
  src = fetchgit {
    name = "http";
    url = "git://github.com/greghendershott/http.git";
    rev = "268318f8fd38c27cd744385885e5f00011f97216";
    sha256 = "09859pik32f7jk1ac25bb1472fxlk2vh9pn9n1731d3jiagxmxdy";
  };
  racketThinBuildInputs = [ self."base" self."html-lib" self."rackunit-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http11" = self.lib.mkRacketDerivation rec {
  pname = "http11";
  src = fetchgit {
    name = "http11";
    url = "https://gitlab.com/RayRacine/http11.git";
    rev = "5d9a2f182168c01ca366cdd45c7bcf78cf8037be";
    sha256 = "050f4mnc3m0qll2k507amwklsj5hjkhykdx7n8r7m29myrgxsqak";
  };
  racketThinBuildInputs = [ self."uri" self."date" self."opt" self."string-util" self."typed-racket-more" self."typed-racket-lib" self."base" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http11-server" = self.lib.mkRacketDerivation rec {
  pname = "http11-server";
  src = fetchgit {
    name = "http11-server";
    url = "https://gitlab.com/RayRacine/http11-server.git";
    rev = "f45e745600995225fb492adc86bc31597b6b9b3d";
    sha256 = "12mzzsv3zxsvjqxqyzhblk3jww652hj0jqmfb6lkcarj3qzih8ki";
  };
  racketThinBuildInputs = [ self."http11" self."string-util" self."uri" self."base" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http2" = self.lib.mkRacketDerivation rec {
  pname = "http2";
  src = fetchgit {
    name = "http2";
    url = "git://github.com/jackfirth/http2.git";
    rev = "7e7d145a1c3a8cac98df51cc1d9081da0ac9fa88";
    sha256 = "1rfmlclxr0wnbddxpdm6bzpfnisn3h2n3qhbmd7b2blw3ryql98a";
  };
  racketThinBuildInputs = [ self."base" self."rebellion" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hygienic-quote-lang" = self.lib.mkRacketDerivation rec {
  pname = "hygienic-quote-lang";
  src = fetchgit {
    name = "hygienic-quote-lang";
    url = "git://github.com/AlexKnauth/hygienic-quote-lang.git";
    rev = "82963703d47bafd51c284067771f46ea410dc725";
    sha256 = "1rljr5l9c6ca37snz5li6sp2g2w0d7jghr017cnavihsmhmcbrrm";
  };
  racketThinBuildInputs = [ self."base" self."hygienic-reader-extension" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hygienic-reader-extension" = self.lib.mkRacketDerivation rec {
  pname = "hygienic-reader-extension";
  src = fetchgit {
    name = "hygienic-reader-extension";
    url = "git://github.com/AlexKnauth/hygienic-reader-extension.git";
    rev = "e00ab648d34f7ea33abd5f9c8b372404bf64aa79";
    sha256 = "0rys77fy4vrmzxfly6n47lrp6ibrcjzklwfv3j925b812jn3yv7a";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hyper-literate" = self.lib.mkRacketDerivation rec {
  pname = "hyper-literate";
  src = fetchgit {
    name = "hyper-literate";
    url = "git://github.com/jsmaniac/hyper-literate.git";
    rev = "ebdeed4cd39196629c9c49f9df00f4ebaff462d1";
    sha256 = "17yjwwr8hs69779qdq07bnrp9bjmapvyw50gkzq8gmrwvy1qpmxw";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."scheme-lib" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-racket-doc" self."scribble-enhanced" self."sexp-diff" self."tr-immutable" self."typed-map-lib" self."debug-scopes" self."syntax-color-lib" self."scribble-lib" self."racket-doc" self."rackunit-doc" self."scribble-doc" self."rackunit-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hyphenate" = self.lib.mkRacketDerivation rec {
  pname = "hyphenate";
  src = fetchgit {
    name = "hyphenate";
    url = "git://github.com/mbutterick/hyphenate.git";
    rev = "36eca7d21b8ddf169d8fef2ebec4acef51de8b47";
    sha256 = "11vgvkhpab1d0klk7h23s3ybzlimqmc3w3liay7x1b91q6kvf77g";
  };
  racketThinBuildInputs = [ self."base" self."sugar" self."txexpr" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "icfp-2014-contracts-talk" = self.lib.mkRacketDerivation rec {
  pname = "icfp-2014-contracts-talk";
  src = fetchgit {
    name = "icfp-2014-contracts-talk";
    url = "git://github.com/rfindler/icfp-2014-contracts-talk.git";
    rev = "e1df17f23d7cd4fbb4fa78c15d6eb3f79c576ddf";
    sha256 = "1slni73fvfwh2a57lcc2vf674gznzpqsg1dg975w4zwywwira26d";
  };
  racketThinBuildInputs = [ self."plot-lib" self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."plot-gui-lib" self."rackunit-lib" self."redex-gui-lib" self."redex-lib" self."slideshow-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "icfp2017-minikanren" = self.lib.mkRacketDerivation rec {
  pname = "icfp2017-minikanren";
  src = self.lib.extractPath {
    path = "src";
    src = fetchgit {
    name = "icfp2017-minikanren";
    url = "git://github.com/AlexKnauth/icfp2017-artifact-auas7pp.git";
    rev = "ff9eca58487ec393fc2d8580e5d1aafedcd20808";
    sha256 = "0gs430q9r6y1gyla08xdsxlbxav6273hlij32gyfahc892ca7jbv";
  };
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "icns" = self.lib.mkRacketDerivation rec {
  pname = "icns";
  src = fetchgit {
    name = "icns";
    url = "git://github.com/LiberalArtist/icns.git";
    rev = "5f33f9cfb163a1075079468b15494d760471dfc0";
    sha256 = "13mp75c3hghb8nkkykbnggk32wfab6kicb4xfjlajglcq2zy6f1b";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "icons" = self.lib.mkRacketDerivation rec {
  pname = "icons";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/icons.zip";
    sha1 = "9e9b0b50ee4756ab235fa7b1383c20d0ef73f469";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "identikon" = self.lib.mkRacketDerivation rec {
  pname = "identikon";
  src = fetchgit {
    name = "identikon";
    url = "git://github.com/DarrenN/identikon.git";
    rev = "d8908ee6955e69466270692599eb9076adc6a28b";
    sha256 = "0pigwr48s9wl34gmhikznpnq2ah8y8hxx62h2w9fvwj7qb78rmxw";
  };
  racketThinBuildInputs = [ self."draw-lib" self."gui-lib" self."base" self."sugar" self."css-tools" self."htdp-lib" self."quickcheck" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "idiocket" = self.lib.mkRacketDerivation rec {
  pname = "idiocket";
  src = fetchgit {
    name = "idiocket";
    url = "git://github.com/zyrolasting/idiocket.git";
    rev = "0ac325617c04c619dd5299f673d88e5c019753e4";
    sha256 = "056fyn17ffvnzl8ax27bpa9laz7wwir5ng50y7gydb8vi4lkw4ck";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "iloveck101" = self.lib.mkRacketDerivation rec {
  pname = "iloveck101";
  src = fetchgit {
    name = "iloveck101";
    url = "git://github.com/Domon/iloveck101.git";
    rev = "eef2eface1d4882e12b298429ed8739af67b9d16";
    sha256 = "06rh64c3agwpdp1diwvp1x2b8ar8ql54488ijimd7560fnsqfh5c";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "image-coloring" = self.lib.mkRacketDerivation rec {
  pname = "image-coloring";
  src = fetchgit {
    name = "image-coloring";
    url = "git://github.com/thoughtstem/image-coloring.git";
    rev = "1cd39f2ccacb2d6f12b577184e5b04f775a7bc4d";
    sha256 = "05wv7g5ypgzplgakr18zaif2qg1d76849hz9sd3phnwjklsdcdlb";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "image-colors" = self.lib.mkRacketDerivation rec {
  pname = "image-colors";
  src = fetchgit {
    name = "image-colors";
    url = "git://github.com/thoughtstem/image-colors.git";
    rev = "1cd39f2ccacb2d6f12b577184e5b04f775a7bc4d";
    sha256 = "05wv7g5ypgzplgakr18zaif2qg1d76849hz9sd3phnwjklsdcdlb";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images" = self.lib.mkRacketDerivation rec {
  pname = "images";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/images.zip";
    sha1 = "5d8ee6522472d54fdf21b276813c2ffdd25eb7c6";
  };
  racketThinBuildInputs = [ self."images-lib" self."images-gui-lib" self."images-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-doc" = self.lib.mkRacketDerivation rec {
  pname = "images-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/images-doc.zip";
    sha1 = "63d4ba00e0e396122b30f0dd9597b48bffe07b81";
  };
  racketThinBuildInputs = [ self."base" self."images-lib" self."draw-doc" self."gui-doc" self."pict-doc" self."slideshow-doc" self."typed-racket-doc" self."draw-lib" self."gui-lib" self."pict-lib" self."racket-doc" self."scribble-lib" self."slideshow-lib" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "images-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/images-gui-lib.zip";
    sha1 = "74eacf894833c5d21f7760e9c26d7ce1dc48c47f";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-lib" = self.lib.mkRacketDerivation rec {
  pname = "images-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/images-lib.zip";
    sha1 = "f7dc15071856ef3bd47f45c82f0c381a7e14ee59";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."typed-racket-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-test" = self.lib.mkRacketDerivation rec {
  pname = "images-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/images-test.zip";
    sha1 = "b57f72791e6ec991fbaa4d4d3ac411c379b9a31c";
  };
  racketThinBuildInputs = [ self."base" self."images-lib" self."pict-lib" self."slideshow-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "impl-excl" = self.lib.mkRacketDerivation rec {
  pname = "impl-excl";
  src = self.lib.extractPath {
    path = "impl-excl";
    src = fetchgit {
    name = "impl-excl";
    url = "git://github.com/philnguyen/impl-excl.git";
    rev = "2be491f8acb71ec6115d96070382e1f5f2d3a2a0";
    sha256 = "11dd1y491ibwhxz9hbn0xrnmfpjsy12dj4p9gw36hd3w8bws56my";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."set-extras" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "in-new-directory" = self.lib.mkRacketDerivation rec {
  pname = "in-new-directory";
  src = fetchgit {
    name = "in-new-directory";
    url = "git://github.com/samth/in-new-directory.git";
    rev = "f7020748288df28ed8371a521781a5d0986582a6";
    sha256 = "0jyaz7gpi3is016xzvy9xvlaapdkwpxqpldsj045hbhhcb2jkmjl";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "inexact-number-lang" = self.lib.mkRacketDerivation rec {
  pname = "inexact-number-lang";
  src = fetchgit {
    name = "inexact-number-lang";
    url = "git://github.com/AlexKnauth/inexact-number-lang.git";
    rev = "b7821d0871a698af4c3833a7f8e2b49e3625eb4a";
    sha256 = "0xlj9fc67h9zzhrcj1vr2lbzwdalc42yp40znr3mzc4cg5201pbi";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "infix" = self.lib.mkRacketDerivation rec {
  pname = "infix";
  src = fetchgit {
    name = "infix";
    url = "git://github.com/soegaard/infix.git";
    rev = "3f7998e509f201f78eb986de0f09e0542a429ad0";
    sha256 = "14wg4dkv1wr3n3llf1fvshdm1fmnn0yjl39yqq7i1ja4ana81ry1";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."scheme-lib" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "infix-syntax" = self.lib.mkRacketDerivation rec {
  pname = "infix-syntax";
  src = fetchgit {
    name = "infix-syntax";
    url = "git://github.com/mromyers/infix-syntax.git";
    rev = "8886395e31dc0b5d0db3a77a75255df15492806c";
    sha256 = "075g3g2rs0wyc0iy1jjvl2yx2bll7a0xppc9wv2w944hh5r9x2kh";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interactive-brokers-api" = self.lib.mkRacketDerivation rec {
  pname = "interactive-brokers-api";
  src = fetchgit {
    name = "interactive-brokers-api";
    url = "git://github.com/evdubs/interactive-brokers-api.git";
    rev = "75e9fde02692e88643434d835e6449f8934e9577";
    sha256 = "1agj3b8zc2vimcs3zdqi7rdslnwzwnqxl04qf3r1gg4w08bp507v";
  };
  racketThinBuildInputs = [ self."base" self."binaryio" self."gregor-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interactive-syntax" = self.lib.mkRacketDerivation rec {
  pname = "interactive-syntax";
  src = fetchgit {
    name = "interactive-syntax";
    url = "git://github.com/videolang/interactive-syntax.git";
    rev = "63d98c42d0225982d23e9ae82ac887fe73ddffd9";
    sha256 = "1vvbidc7xr4hkxrz1gfn2dxa5q9fanqyfa6bj0wbm0m6nq6ydldy";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."data-lib" self."drracket-plugin-lib" self."gui-lib" self."images-lib" self."math-lib" self."syntax-color-lib" self."wxme-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interconfection" = self.lib.mkRacketDerivation rec {
  pname = "interconfection";
  src = self.lib.extractPath {
    path = "interconfection";
    src = fetchgit {
    name = "interconfection";
    url = "git://github.com/lathe/interconfection-for-racket.git";
    rev = "b66432a6fab1b48f6d33afaec4b1f630fc02a064";
    sha256 = "16j7fwsib0185bsy0fmpc4k3glsa1pa8dhsvkxp9hfr6q0l5jgr6";
  };
  };
  racketThinBuildInputs = [ self."interconfection-doc" self."interconfection-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interconfection-doc" = self.lib.mkRacketDerivation rec {
  pname = "interconfection-doc";
  src = self.lib.extractPath {
    path = "interconfection-doc";
    src = fetchgit {
    name = "interconfection-doc";
    url = "git://github.com/lathe/interconfection-for-racket.git";
    rev = "b66432a6fab1b48f6d33afaec4b1f630fc02a064";
    sha256 = "16j7fwsib0185bsy0fmpc4k3glsa1pa8dhsvkxp9hfr6q0l5jgr6";
  };
  };
  racketThinBuildInputs = [ self."base" self."interconfection-lib" self."lathe-comforts-doc" self."lathe-comforts-lib" self."parendown-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interconfection-lib" = self.lib.mkRacketDerivation rec {
  pname = "interconfection-lib";
  src = self.lib.extractPath {
    path = "interconfection-lib";
    src = fetchgit {
    name = "interconfection-lib";
    url = "git://github.com/lathe/interconfection-for-racket.git";
    rev = "b66432a6fab1b48f6d33afaec4b1f630fc02a064";
    sha256 = "16j7fwsib0185bsy0fmpc4k3glsa1pa8dhsvkxp9hfr6q0l5jgr6";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interconfection-test" = self.lib.mkRacketDerivation rec {
  pname = "interconfection-test";
  src = self.lib.extractPath {
    path = "interconfection-test";
    src = fetchgit {
    name = "interconfection-test";
    url = "git://github.com/lathe/interconfection-for-racket.git";
    rev = "b66432a6fab1b48f6d33afaec4b1f630fc02a064";
    sha256 = "16j7fwsib0185bsy0fmpc4k3glsa1pa8dhsvkxp9hfr6q0l5jgr6";
  };
  };
  racketThinBuildInputs = [ self."base" self."interconfection-lib" self."lathe-comforts-lib" self."rackunit-lib" self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "intern" = self.lib.mkRacketDerivation rec {
  pname = "intern";
  src = self.lib.extractPath {
    path = "intern";
    src = fetchgit {
    name = "intern";
    url = "git://github.com/philnguyen/intern.git";
    rev = "e2b46f803fe9d83368bde168fca8559f1210cfe3";
    sha256 = "04v26jn50kapqyi044drwlrhq6h50nn9lzygmrpdkv2ynq8k7pm6";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "io" = self.lib.mkRacketDerivation rec {
  pname = "io";
  src = fetchgit {
    name = "io";
    url = "git://github.com/samth/io.rkt.git";
    rev = "db8413c802782bfc3de706cc1cb8dab6fe4f941e";
    sha256 = "0m83nsi7ppviwc5yhfy0wmrwmcbvhb1f0cf4wgvgif9sa3k09nbg";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."in-new-directory" self."compatibility-lib" self."rackunit-gui" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ipoe" = self.lib.mkRacketDerivation rec {
  pname = "ipoe";
  src = self.lib.extractPath {
    path = "ipoe";
    src = fetchgit {
    name = "ipoe";
    url = "git://github.com/bennn/ipoe.git";
    rev = "afdbc3baf2bcb8b7e09a23d8e656c6b69a61f3ad";
    sha256 = "1q3ksarp0h1gbfqyqfbk2xay63z7nv96l3x44xz0lp6lkzcf5g49";
  };
  };
  racketThinBuildInputs = [ self."base" self."basedir" self."db-lib" self."html-lib" self."html-parsing" self."levenshtein" self."rackunit-lib" self."readline-lib" self."reprovide-lang" self."sxml" self."basedir" self."net-doc" self."racket-doc" self."rackunit-abbrevs" self."rackunit-lib" self."scribble-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "iracket" = self.lib.mkRacketDerivation rec {
  pname = "iracket";
  src = fetchgit {
    name = "iracket";
    url = "git://github.com/rmculpepper/iracket.git";
    rev = "d2ffb50c63a20df68a52359214697657eb9fb850";
    sha256 = "0ygxzc4ix58w7zbvhwzsily9v3ahaqw1k3hjdli98205z922a7qq";
  };
  racketThinBuildInputs = [ self."base" self."zeromq-r-lib" self."sandbox-lib" self."uuid" self."sha" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "irc" = self.lib.mkRacketDerivation rec {
  pname = "irc";
  src = fetchgit {
    name = "irc";
    url = "git://github.com/schuster/racket-irc.git";
    rev = "50637fdc83da6c415b7ae26683a56d394c9ffe61";
    sha256 = "01j1chmaka78jl2788bqa9w52s4siynv9cbr0l6g07hivpylxfb5";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "irc-client" = self.lib.mkRacketDerivation rec {
  pname = "irc-client";
  src = fetchgit {
    name = "irc-client";
    url = "git://github.com/lexi-lambda/racket-irc-client.git";
    rev = "dc3958adf0d8e7a8bf34820cb7bc6630eb18d622";
    sha256 = "06xvmf5p7vliy6cl5zyqif8dl2mvhwqkz94cd35n07rkfsrsxfzr";
  };
  racketThinBuildInputs = [ self."base" self."irc" self."typed-racket-lib" self."typed-racket-more" self."racket-doc" self."scribble-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "iswim" = self.lib.mkRacketDerivation rec {
  pname = "iswim";
  src = fetchgit {
    name = "iswim";
    url = "git://github.com/jeapostrophe/iswim.git";
    rev = "7d6fe87391475b22828a39b344fd7b983f7018f7";
    sha256 = "1igzw35qnf279zs18nb03k8gmi85xbri2giw2ld29xr5q7zzmy0a";
  };
  racketThinBuildInputs = [ self."draw-lib" self."gui-lib" self."pict-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "iu-pict" = self.lib.mkRacketDerivation rec {
  pname = "iu-pict";
  src = fetchgit {
    name = "iu-pict";
    url = "git://github.com/david-christiansen/iu-pict.git";
    rev = "42072a907d65bbfd09077592a20bfb130fc5a35a";
    sha256 = "105ykgwfi4q9ckbswbb41yk859pflcid4mkayayzpzanpa4vjjw1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "j" = self.lib.mkRacketDerivation rec {
  pname = "j";
  src = fetchgit {
    name = "j";
    url = "git://github.com/lwhjp/racket-jlang.git";
    rev = "021c40382f95d1a6dc0b329a152a171465b9bc75";
    sha256 = "09k3qma019a7w2awspbbrg2rxdiamvh8bz8hjm4r7bgksmrny5g0";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."math-lib" self."parser-tools-lib" self."math-doc" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jack-ease" = self.lib.mkRacketDerivation rec {
  pname = "jack-ease";
  src = fetchgit {
    name = "jack-ease";
    url = "git://github.com/jackfirth/racket-ease.git";
    rev = "3a7149ded68be348611e346742feac85fca6d74f";
    sha256 = "1cq697hfsmq755d759j3lnz72596vz5zhgvl0ydzg5cf01jp8mls";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."base" self."sweet-exp" self."lens" self."fancy-app" self."rackunit-lib" self."cover" self."racket-doc" self."scribble-lib" self."doc-coverage" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jack-posn" = self.lib.mkRacketDerivation rec {
  pname = "jack-posn";
  src = fetchgit {
    name = "jack-posn";
    url = "git://github.com/jackfirth/racket-posn.git";
    rev = "402ca7d3d5db28b04d82ff825a684c4995dcf355";
    sha256 = "19npmcxj0ab5kv8f0n9cj8lnkvkxrsj17rpcrcia98ni0xbf3mc8";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."base" self."sweet-exp" self."fancy-app" self."cover" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."doc-coverage" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jack-scribble-example" = self.lib.mkRacketDerivation rec {
  pname = "jack-scribble-example";
  src = fetchgit {
    name = "jack-scribble-example";
    url = "git://github.com/jackfirth/scribble-example.git";
    rev = "8ea8ae06d859b607fd3600a68a806513580e1867";
    sha256 = "0nkmc2hzxgghs5smpdlqa6nrccp7mqa6lan6qbkryh49y8izhm7w";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."base" self."sweet-exp-lib" self."reprovide-lang-lib" self."fancy-app" self."scribble-doc" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."doc-coverage" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "java" = self.lib.mkRacketDerivation rec {
  pname = "java";
  src = fetchgit {
    name = "java";
    url = "git://github.com/jbclements/java.git";
    rev = "c2d1359b05567fb9352178cedeba2dfc30ddc9ca";
    sha256 = "0vldbmhzc3zjv6gbhbcqdrllan21dp59vjz1hk5xq85dgy0d9f67";
  };
  racketThinBuildInputs = [ self."dherman-struct" self."io" self."base" self."compatibility-lib" self."parser-tools-lib" self."srfi-lite-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "java-lexer" = self.lib.mkRacketDerivation rec {
  pname = "java-lexer";
  src = fetchgit {
    name = "java-lexer";
    url = "git://github.com/stamourv/java-lexer.git";
    rev = "83e12122919d4582d63bea5b051cbeab6ee32c57";
    sha256 = "1a5dapfl7bwm2cqxgzlbv65ympgr19rmr530z4nzw0mmfbz2hzrp";
  };
  racketThinBuildInputs = [ self."base" self."profj" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "java-processing" = self.lib.mkRacketDerivation rec {
  pname = "java-processing";
  src = fetchgit {
    name = "java-processing";
    url = "git://github.com/thoughtstem/java-processing.git";
    rev = "8a232dac0405edf13067397364c9dbd702addca6";
    sha256 = "10264j04p1jc9ga1rpzr9x338rxbyn53kpknn48nsf5vlqi9s9a2";
  };
  racketThinBuildInputs = [ self."racket-to" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "javascript" = self.lib.mkRacketDerivation rec {
  pname = "javascript";
  src = fetchgit {
    name = "javascript";
    url = "git://github.com/samth/javascript.plt.git";
    rev = "327c2de5e09f885b682f80524ff3c12ef6c47543";
    sha256 = "0vvjqyhl30wgi5bc82fjr30i5dvfa68fh4b9xyqy921m1gp6xgzw";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket-plugin-lib" self."gui-lib" self."parameter" self."parser-tools-lib" self."planet-lib" self."scheme-lib" self."set" self."srfi-lite-lib" self."string-constants-lib" self."unstable-contract-lib" self."pprint" self."in-new-directory" self."parser-tools-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."unstable-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jen" = self.lib.mkRacketDerivation rec {
  pname = "jen";
  src = self.lib.extractPath {
    path = "jen";
    src = fetchgit {
    name = "jen";
    url = "git://github.com/HeladoDeBrownie/jen.git";
    rev = "8af59d936c0218d4460eebcbeabc52aae1b6d58e";
    sha256 = "1092ahmp7jwnsl12vhhp5zg1z3ps2r9as0ysy452ih70dn02153m";
  };
  };
  racketThinBuildInputs = [ self."jen-lib" self."jen-doc" self."jen-samples" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jen-doc" = self.lib.mkRacketDerivation rec {
  pname = "jen-doc";
  src = self.lib.extractPath {
    path = "jen-doc";
    src = fetchgit {
    name = "jen-doc";
    url = "git://github.com/HeladoDeBrownie/jen.git";
    rev = "8af59d936c0218d4460eebcbeabc52aae1b6d58e";
    sha256 = "1092ahmp7jwnsl12vhhp5zg1z3ps2r9as0ysy452ih70dn02153m";
  };
  };
  racketThinBuildInputs = [ self."base" self."jen-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jen-lib" = self.lib.mkRacketDerivation rec {
  pname = "jen-lib";
  src = self.lib.extractPath {
    path = "jen-lib";
    src = fetchgit {
    name = "jen-lib";
    url = "git://github.com/HeladoDeBrownie/jen.git";
    rev = "8af59d936c0218d4460eebcbeabc52aae1b6d58e";
    sha256 = "1092ahmp7jwnsl12vhhp5zg1z3ps2r9as0ysy452ih70dn02153m";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "jen-samples" = self.lib.mkRacketDerivation rec {
  pname = "jen-samples";
  src = self.lib.extractPath {
    path = "jen-samples";
    src = fetchgit {
    name = "jen-samples";
    url = "git://github.com/HeladoDeBrownie/jen.git";
    rev = "8af59d936c0218d4460eebcbeabc52aae1b6d58e";
    sha256 = "1092ahmp7jwnsl12vhhp5zg1z3ps2r9as0ysy452ih70dn02153m";
  };
  };
  racketThinBuildInputs = [ self."base" self."jen-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "job-queue" = self.lib.mkRacketDerivation rec {
  pname = "job-queue";
  src = self.lib.extractPath {
    path = "job-queue";
    src = fetchgit {
    name = "job-queue";
    url = "git://github.com/jeapostrophe/job-queue.git";
    rev = "0a2c349636aa88b06c9c299ef201494df648b164";
    sha256 = "066m6rjc3qvlnr15jm6n5mdl4cgc5n12imwkj3aw56sc2cyhs1kd";
  };
  };
  racketThinBuildInputs = [ self."base" self."job-queue-lib" self."job-queue-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "job-queue-doc" = self.lib.mkRacketDerivation rec {
  pname = "job-queue-doc";
  src = self.lib.extractPath {
    path = "job-queue-doc";
    src = fetchgit {
    name = "job-queue-doc";
    url = "git://github.com/jeapostrophe/job-queue.git";
    rev = "0a2c349636aa88b06c9c299ef201494df648b164";
    sha256 = "066m6rjc3qvlnr15jm6n5mdl4cgc5n12imwkj3aw56sc2cyhs1kd";
  };
  };
  racketThinBuildInputs = [ self."base" self."job-queue-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "job-queue-lib" = self.lib.mkRacketDerivation rec {
  pname = "job-queue-lib";
  src = self.lib.extractPath {
    path = "job-queue-lib";
    src = fetchgit {
    name = "job-queue-lib";
    url = "git://github.com/jeapostrophe/job-queue.git";
    rev = "0a2c349636aa88b06c9c299ef201494df648b164";
    sha256 = "066m6rjc3qvlnr15jm6n5mdl4cgc5n12imwkj3aw56sc2cyhs1kd";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "js-voxel" = self.lib.mkRacketDerivation rec {
  pname = "js-voxel";
  src = fetchgit {
    name = "js-voxel";
    url = "git://github.com/dedbox/racket-js-voxel.git";
    rev = "7a97d657b2d4729c1f79aa2fb52435eadff92650";
    sha256 = "0dp4q9275y92qrfh5g7cwvlg2mzc4ihjf4iwxcqpz7vh7n3yri5h";
  };
  racketThinBuildInputs = [ self."base" self."glm" self."rfc6455" self."web-server-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-parsing" = self.lib.mkRacketDerivation rec {
  pname = "json-parsing";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/json-parsing.zip";
    sha1 = "28a5d163d4785990b265ff5d3499e8ce594c672d";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-pointer" = self.lib.mkRacketDerivation rec {
  pname = "json-pointer";
  src = fetchgit {
    name = "json-pointer";
    url = "git://github.com/jessealama/json-pointer.git";
    rev = "a9c14d934daf80055afeccf751c092fd53ce7221";
    sha256 = "0an4g5f5qbrm0rz1jnsyikp452l1jkdh6ycr53s75yk2k2dp2hx5";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."ejs" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-socket" = self.lib.mkRacketDerivation rec {
  pname = "json-socket";
  src = fetchgit {
    name = "json-socket";
    url = "git://github.com/mordae/racket-json-socket.git";
    rev = "0acf5117ed335133e30a4ab6593278a4534ac42e";
    sha256 = "16xj5ny2146dmpql3izid78qqdx40h1gmdxs5fpfy1b8sg75rb1w";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-sourcery" = self.lib.mkRacketDerivation rec {
  pname = "json-sourcery";
  src = self.lib.extractPath {
    path = "json-sourcery";
    src = fetchgit {
    name = "json-sourcery";
    url = "git://github.com/adjkant/json-sourcery.git";
    rev = "a0b1646afedabb022550fd2b1f7c8052ac8ae5b6";
    sha256 = "0aiag9pq48yjp622syw9b2yggsqq8d1sdzbaxri9lajhcyq5pwil";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-sourcery-lib" = self.lib.mkRacketDerivation rec {
  pname = "json-sourcery-lib";
  src = self.lib.extractPath {
    path = "json-sourcery-lib";
    src = fetchgit {
    name = "json-sourcery-lib";
    url = "git://github.com/adjkant/json-sourcery.git";
    rev = "b8f98e44a2c98266315f9c8f78156972f6bc649d";
    sha256 = "0gv0r34lkj9r6p9pjkba0k43gw7xd5g6ghnzkp0wzh86svzf1zpv";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "json-type-provider" = self.lib.mkRacketDerivation rec {
  pname = "json-type-provider";
  src = self.lib.extractPath {
    path = "json-type-provider";
    src = fetchgit {
    name = "json-type-provider";
    url = "git://github.com/philnguyen/json-type-provider.git";
    rev = "d2c965706f85a9d66a62321ebe3c20a90e13b17f";
    sha256 = "17ggqsprmwmqx73d9cllrv8xq8wk64mz8a1p2lviz8b5b4ig0f9x";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "k-infix" = self.lib.mkRacketDerivation rec {
  pname = "k-infix";
  src = fetchgit {
    name = "k-infix";
    url = "git://github.com/BourgondAries/k-infix.git";
    rev = "07ed4c23905ea8b2b85a5f321d56ad038170766f";
    sha256 = "0ig2m5syvxwx25nzw7w8dib512gy1wnydxykrhfbw3j59bkk4shw";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."memoize" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kernel" = self.lib.mkRacketDerivation rec {
  pname = "kernel";
  src = fetchgit {
    name = "kernel";
    url = "git://github.com/mordae/racket-kernel.git";
    rev = "8602042a9d6109399dfa7f492b5af7af6c88f597";
    sha256 = "00n53nfy90nadiv5x6ik3rkvlc6dd5z23vpvmc3wvmjyjxk5jji8";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."rtnl" self."sysfs" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kinda-ferpy" = self.lib.mkRacketDerivation rec {
  pname = "kinda-ferpy";
  src = fetchgit {
    name = "kinda-ferpy";
    url = "git://github.com/zyrolasting/kinda-ferpy.git";
    rev = "d70b3fd0dc7c8793a954599ed708414a481afab1";
    sha256 = "1a7akw4qrim4wngqgl0j5q399lp007d48236iyz064fjbklh6kml";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kitco" = self.lib.mkRacketDerivation rec {
  pname = "kitco";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/kitco.zip";
    sha1 = "f26e9472df8d0fd74c6128d9c342d205c4003916";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo" = self.lib.mkRacketDerivation rec {
  pname = "koyo";
  src = self.lib.extractPath {
    path = "koyo";
    src = fetchgit {
    name = "koyo";
    url = "git://github.com/Bogdanp/koyo.git";
    rev = "bc1693a285aede4dc4d7ad5a210eb4e468f29593";
    sha256 = "0m1h2g0zh0mn7g1lc3sya4dmiqhq3gp0dzf27mrgivjkls89g6hj";
  };
  };
  racketThinBuildInputs = [ self."koyo-doc" self."koyo-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-doc" = self.lib.mkRacketDerivation rec {
  pname = "koyo-doc";
  src = self.lib.extractPath {
    path = "koyo-doc";
    src = fetchgit {
    name = "koyo-doc";
    url = "git://github.com/Bogdanp/koyo.git";
    rev = "bc1693a285aede4dc4d7ad5a210eb4e468f29593";
    sha256 = "0m1h2g0zh0mn7g1lc3sya4dmiqhq3gp0dzf27mrgivjkls89g6hj";
  };
  };
  racketThinBuildInputs = [ self."base" self."component-doc" self."component-lib" self."db-lib" self."koyo-lib" self."sandbox-lib" self."scribble-lib" self."web-server-lib" self."db-doc" self."net-doc" self."racket-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-lib" = self.lib.mkRacketDerivation rec {
  pname = "koyo-lib";
  src = self.lib.extractPath {
    path = "koyo-lib";
    src = fetchgit {
    name = "koyo-lib";
    url = "git://github.com/Bogdanp/koyo.git";
    rev = "bc1693a285aede4dc4d7ad5a210eb4e468f29593";
    sha256 = "0m1h2g0zh0mn7g1lc3sya4dmiqhq3gp0dzf27mrgivjkls89g6hj";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."component-lib" self."db-lib" self."errortrace-lib" self."gregor-lib" self."html-lib" self."readline-lib" self."srfi-lite-lib" self."web-server-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-north" = self.lib.mkRacketDerivation rec {
  pname = "koyo-north";
  src = fetchgit {
    name = "koyo-north";
    url = "git://github.com/Bogdanp/koyo-north.git";
    rev = "a552fe709655a15d1a1382a909fe2466f173f27c";
    sha256 = "0in0kv9l0cb78jkqqyh2vp2sajxi8bdln1zy7xc59bzk9lh4f3bk";
  };
  racketThinBuildInputs = [ self."base" self."component-lib" self."db-lib" self."koyo-lib" self."north" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-postmark" = self.lib.mkRacketDerivation rec {
  pname = "koyo-postmark";
  src = fetchgit {
    name = "koyo-postmark";
    url = "git://github.com/Bogdanp/koyo-postmark.git";
    rev = "ceeb619d555ef49c2cec42c0b890a97fd1377f89";
    sha256 = "09n9vg8a626k1jvfnifryqd23swywkwa4sh230xc61nlmvsq8z3d";
  };
  racketThinBuildInputs = [ self."base" self."koyo-lib" self."postmark-client" self."koyo-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-sentry" = self.lib.mkRacketDerivation rec {
  pname = "koyo-sentry";
  src = fetchgit {
    name = "koyo-sentry";
    url = "git://github.com/Bogdanp/koyo-sentry.git";
    rev = "f04efd69d239347bc44cba1587deb1bc3d5ba8c7";
    sha256 = "0n3nf74kjn79vg1w7y5k044liigwyg1r2zjbxbykwa2frf3f7j4d";
  };
  racketThinBuildInputs = [ self."base" self."koyo-lib" self."sentry-lib" self."web-server-lib" self."racket-doc" self."scribble-lib" self."sentry-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "koyo-test" = self.lib.mkRacketDerivation rec {
  pname = "koyo-test";
  src = self.lib.extractPath {
    path = "koyo-test";
    src = fetchgit {
    name = "koyo-test";
    url = "git://github.com/Bogdanp/koyo.git";
    rev = "bc1693a285aede4dc4d7ad5a210eb4e468f29593";
    sha256 = "0m1h2g0zh0mn7g1lc3sya4dmiqhq3gp0dzf27mrgivjkls89g6hj";
  };
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."component-lib" self."db-lib" self."gregor-lib" self."koyo-lib" self."rackunit-lib" self."srfi-lite-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kw-make-struct" = self.lib.mkRacketDerivation rec {
  pname = "kw-make-struct";
  src = self.lib.extractPath {
    path = "kw-make-struct";
    src = fetchgit {
    name = "kw-make-struct";
    url = "git://github.com/AlexKnauth/kw-make-struct.git";
    rev = "260803074a12bba911646dec8e26b26f674952b3";
    sha256 = "14zyqadz1crf3pilwbzgyxab8xv7rx8vwcw11zwja0h5xmmil6ma";
  };
  };
  racketThinBuildInputs = [ self."base" self."kw-make-struct-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kw-make-struct-lib" = self.lib.mkRacketDerivation rec {
  pname = "kw-make-struct-lib";
  src = self.lib.extractPath {
    path = "kw-make-struct-lib";
    src = fetchgit {
    name = "kw-make-struct-lib";
    url = "git://github.com/AlexKnauth/kw-make-struct.git";
    rev = "260803074a12bba911646dec8e26b26f674952b3";
    sha256 = "14zyqadz1crf3pilwbzgyxab8xv7rx8vwcw11zwja0h5xmmil6ma";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "kw-utils" = self.lib.mkRacketDerivation rec {
  pname = "kw-utils";
  src = fetchgit {
    name = "kw-utils";
    url = "git://github.com/AlexKnauth/kw-utils.git";
    rev = "1acb6feff772064010574c0a68d464146cd7d29c";
    sha256 = "1vg64zlsf8pmd307w9f7kybslagbza1dv95g7kkr74iwrgfbjwfs";
  };
  racketThinBuildInputs = [ self."base" self."sweet-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."rackjure" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lambda-calculus" = self.lib.mkRacketDerivation rec {
  pname = "lambda-calculus";
  src = fetchgit {
    name = "lambda-calculus";
    url = "git://github.com/oransimhony/lambda-calculus.git";
    rev = "fd13e81f1df22fc9044f0cdcd1cead8504d335d8";
    sha256 = "0gxirnd48lpq5lppylqx1yc0vngn8v26cax9wvcc487m0hqi3r23";
  };
  racketThinBuildInputs = [ self."beautiful-racket-lib" self."rackunit-lib" self."base" self."brag" self."beautiful-racket" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lambda-sh" = self.lib.mkRacketDerivation rec {
  pname = "lambda-sh";
  src = fetchgit {
    name = "lambda-sh";
    url = "git://github.com/wargrey/lambda-shell.git";
    rev = "308c433c89b5694c3e5b19c8642e8ce0c3644020";
    sha256 = "0rf7p696yp14lv1vpbaxiwqwms6by39m6fxdf164g151fzhaawr4";
  };
  racketThinBuildInputs = [ self."base" self."digimon" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."pict-lib" self."math-lib" self."digimon" self."scribble-lib" self."pict-lib" self."math-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lambdajam-2015-racket-pl-pl" = self.lib.mkRacketDerivation rec {
  pname = "lambdajam-2015-racket-pl-pl";
  src = fetchgit {
    name = "lambdajam-2015-racket-pl-pl";
    url = "git://github.com/rfindler/lambdajam-2015-racket-pl-pl.git";
    rev = "4c9001dca9fb72c885d8cc1bef057ac8f56c24d0";
    sha256 = "1n6vsl5dj1zb83dqzdl5h8fdckmn78lr0gfnsfk98sva9szg6whv";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."lazy" self."parser-tools-lib" self."rackunit-lib" self."scheme-lib" self."schemeunit" self."slideshow-lib" self."typed-racket-lib" self."lang-slide" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lang-file" = self.lib.mkRacketDerivation rec {
  pname = "lang-file";
  src = self.lib.extractPath {
    path = "lang-file";
    src = fetchgit {
    name = "lang-file";
    url = "git://github.com/AlexKnauth/lang-file.git";
    rev = "435925c4abcf4835c6ea2afdbbf6d051272cba66";
    sha256 = "1zi3gb117c77xr114fwicpm13cjli16lpghlv0c3pl7mkqcdarsg";
  };
  };
  racketThinBuildInputs = [ self."base" self."lang-file-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lang-file-lib" = self.lib.mkRacketDerivation rec {
  pname = "lang-file-lib";
  src = self.lib.extractPath {
    path = "lang-file-lib";
    src = fetchgit {
    name = "lang-file-lib";
    url = "git://github.com/AlexKnauth/lang-file.git";
    rev = "435925c4abcf4835c6ea2afdbbf6d051272cba66";
    sha256 = "1zi3gb117c77xr114fwicpm13cjli16lpghlv0c3pl7mkqcdarsg";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lang-slide" = self.lib.mkRacketDerivation rec {
  pname = "lang-slide";
  src = fetchgit {
    name = "lang-slide";
    url = "git://github.com/samth/lang-slide.git";
    rev = "ea86af49c3d7fe2fe0e80c1c9488b3447a0efbdd";
    sha256 = "0kiwhyx00140f415843bh4frgnlf5g9wabmmivgy7ml7v9nf1q4z";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."scheme-lib" self."slideshow-lib" self."unstable-lib" self."scribble-lib" self."racket-doc" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "latex-pict" = self.lib.mkRacketDerivation rec {
  pname = "latex-pict";
  src = fetchgit {
    name = "latex-pict";
    url = "git://github.com/soegaard/latex-pict.git";
    rev = "e9d2a0ad1341bb7a34173c337e9a33ccdc1ca2be";
    sha256 = "19x1cg2x6m64qa5ka9jmvq88lvpax3zx8bh8vhhsxbpqr7s5k19m";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."racket-poppler" self."scribble-lib" self."racket-doc" self."draw-doc" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "latex-utils" = self.lib.mkRacketDerivation rec {
  pname = "latex-utils";
  src = fetchgit {
    name = "latex-utils";
    url = "git://github.com/dented42/latex-utils.git";
    rev = "631ad9b13b837f4109932252c85bc1bf6f0ae752";
    sha256 = "06slak52xlr6zmsrbf9bkvnhpkqk0bp7ni7y7r5r8m5i99jd56d3";
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."scribble-lib" self."seq-no-order" self."at-exp-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-comforts" = self.lib.mkRacketDerivation rec {
  pname = "lathe-comforts";
  src = self.lib.extractPath {
    path = "lathe-comforts";
    src = fetchgit {
    name = "lathe-comforts";
    url = "git://github.com/lathe/lathe-comforts-for-racket.git";
    rev = "4ce5e4bd92828aa9994164b1d35265dcad02fe26";
    sha256 = "1r786zwfj07axxd4wp7hrasdi49ijhl6j5lw2q0zmf6hbkmcl0d7";
  };
  };
  racketThinBuildInputs = [ self."lathe-comforts-doc" self."lathe-comforts-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-comforts-doc" = self.lib.mkRacketDerivation rec {
  pname = "lathe-comforts-doc";
  src = self.lib.extractPath {
    path = "lathe-comforts-doc";
    src = fetchgit {
    name = "lathe-comforts-doc";
    url = "git://github.com/lathe/lathe-comforts-for-racket.git";
    rev = "4ce5e4bd92828aa9994164b1d35265dcad02fe26";
    sha256 = "1r786zwfj07axxd4wp7hrasdi49ijhl6j5lw2q0zmf6hbkmcl0d7";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown-doc" self."parendown-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-comforts-lib" = self.lib.mkRacketDerivation rec {
  pname = "lathe-comforts-lib";
  src = self.lib.extractPath {
    path = "lathe-comforts-lib";
    src = fetchgit {
    name = "lathe-comforts-lib";
    url = "git://github.com/lathe/lathe-comforts-for-racket.git";
    rev = "4ce5e4bd92828aa9994164b1d35265dcad02fe26";
    sha256 = "1r786zwfj07axxd4wp7hrasdi49ijhl6j5lw2q0zmf6hbkmcl0d7";
  };
  };
  racketThinBuildInputs = [ self."base" self."parendown" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-comforts-test" = self.lib.mkRacketDerivation rec {
  pname = "lathe-comforts-test";
  src = self.lib.extractPath {
    path = "lathe-comforts-test";
    src = fetchgit {
    name = "lathe-comforts-test";
    url = "git://github.com/lathe/lathe-comforts-for-racket.git";
    rev = "4ce5e4bd92828aa9994164b1d35265dcad02fe26";
    sha256 = "1r786zwfj07axxd4wp7hrasdi49ijhl6j5lw2q0zmf6hbkmcl0d7";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-morphisms" = self.lib.mkRacketDerivation rec {
  pname = "lathe-morphisms";
  src = self.lib.extractPath {
    path = "lathe-morphisms";
    src = fetchgit {
    name = "lathe-morphisms";
    url = "git://github.com/lathe/lathe-morphisms-for-racket.git";
    rev = "d7c244f82014259e12681d598ae006534a62471d";
    sha256 = "0h8i05w07103vg8p1c4iv5b28a6h98vraap071f30jxpaa2vsyrc";
  };
  };
  racketThinBuildInputs = [ self."lathe-morphisms-doc" self."lathe-morphisms-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-morphisms-doc" = self.lib.mkRacketDerivation rec {
  pname = "lathe-morphisms-doc";
  src = self.lib.extractPath {
    path = "lathe-morphisms-doc";
    src = fetchgit {
    name = "lathe-morphisms-doc";
    url = "git://github.com/lathe/lathe-morphisms-for-racket.git";
    rev = "d7c244f82014259e12681d598ae006534a62471d";
    sha256 = "0h8i05w07103vg8p1c4iv5b28a6h98vraap071f30jxpaa2vsyrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-doc" self."lathe-comforts-lib" self."lathe-morphisms-lib" self."parendown-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-morphisms-lib" = self.lib.mkRacketDerivation rec {
  pname = "lathe-morphisms-lib";
  src = self.lib.extractPath {
    path = "lathe-morphisms-lib";
    src = fetchgit {
    name = "lathe-morphisms-lib";
    url = "git://github.com/lathe/lathe-morphisms-for-racket.git";
    rev = "d7c244f82014259e12681d598ae006534a62471d";
    sha256 = "0h8i05w07103vg8p1c4iv5b28a6h98vraap071f30jxpaa2vsyrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-morphisms-test" = self.lib.mkRacketDerivation rec {
  pname = "lathe-morphisms-test";
  src = self.lib.extractPath {
    path = "lathe-morphisms-test";
    src = fetchgit {
    name = "lathe-morphisms-test";
    url = "git://github.com/lathe/lathe-morphisms-for-racket.git";
    rev = "d7c244f82014259e12681d598ae006534a62471d";
    sha256 = "0h8i05w07103vg8p1c4iv5b28a6h98vraap071f30jxpaa2vsyrc";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-morphisms-lib" self."parendown-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-ordinals" = self.lib.mkRacketDerivation rec {
  pname = "lathe-ordinals";
  src = self.lib.extractPath {
    path = "lathe-ordinals";
    src = fetchgit {
    name = "lathe-ordinals";
    url = "git://github.com/lathe/lathe-ordinals-for-racket.git";
    rev = "d6261936fbd274104c923fc70a2bb7c2a5908339";
    sha256 = "04ra9bzlx7v77nwb8q6cwv23mc2c6rq1xzwgl4r6385ca8cnm7yf";
  };
  };
  racketThinBuildInputs = [ self."lathe-ordinals-doc" self."lathe-ordinals-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-ordinals-doc" = self.lib.mkRacketDerivation rec {
  pname = "lathe-ordinals-doc";
  src = self.lib.extractPath {
    path = "lathe-ordinals-doc";
    src = fetchgit {
    name = "lathe-ordinals-doc";
    url = "git://github.com/lathe/lathe-ordinals-for-racket.git";
    rev = "d6261936fbd274104c923fc70a2bb7c2a5908339";
    sha256 = "04ra9bzlx7v77nwb8q6cwv23mc2c6rq1xzwgl4r6385ca8cnm7yf";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-doc" self."lathe-comforts-lib" self."lathe-ordinals-lib" self."parendown-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-ordinals-lib" = self.lib.mkRacketDerivation rec {
  pname = "lathe-ordinals-lib";
  src = self.lib.extractPath {
    path = "lathe-ordinals-lib";
    src = fetchgit {
    name = "lathe-ordinals-lib";
    url = "git://github.com/lathe/lathe-ordinals-for-racket.git";
    rev = "d6261936fbd274104c923fc70a2bb7c2a5908339";
    sha256 = "04ra9bzlx7v77nwb8q6cwv23mc2c6rq1xzwgl4r6385ca8cnm7yf";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lathe-ordinals-test" = self.lib.mkRacketDerivation rec {
  pname = "lathe-ordinals-test";
  src = self.lib.extractPath {
    path = "lathe-ordinals-test";
    src = fetchgit {
    name = "lathe-ordinals-test";
    url = "git://github.com/lathe/lathe-ordinals-for-racket.git";
    rev = "d6261936fbd274104c923fc70a2bb7c2a5908339";
    sha256 = "04ra9bzlx7v77nwb8q6cwv23mc2c6rq1xzwgl4r6385ca8cnm7yf";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-ordinals-lib" self."parendown-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lazy" = self.lib.mkRacketDerivation rec {
  pname = "lazy";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/lazy.zip";
    sha1 = "d7784982054687a10038214a34e742c276384240";
  };
  racketThinBuildInputs = [ self."base" self."drracket-plugin-lib" self."htdp-lib" self."string-constants-lib" self."compatibility-lib" self."mzscheme-doc" self."scheme-lib" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lazytree" = self.lib.mkRacketDerivation rec {
  pname = "lazytree";
  src = fetchgit {
    name = "lazytree";
    url = "git://github.com/countvajhula/lazytree.git";
    rev = "5ed90f728f7530b6115b7cf80dcb8ddede7256ae";
    sha256 = "005sq39v9pp7sgiji95p8d9gqchwy14idvn8di47828889dxskxq";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."Relation" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."collections-doc" self."functional-doc" self."rackunit-lib" self."pict-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ldap" = self.lib.mkRacketDerivation rec {
  pname = "ldap";
  src = fetchgit {
    name = "ldap";
    url = "git://github.com/jeapostrophe/ldap.git";
    rev = "e7440a2632f01563182f277135ab066c41157639";
    sha256 = "0qrnz71q2rbdwskxnbfcabvz3d6hjjmv55nfisvi540wv704hvcq";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ldap-ffi" = self.lib.mkRacketDerivation rec {
  pname = "ldap-ffi";
  src = fetchgit {
    name = "ldap-ffi";
    url = "git://github.com/DmHertz/ldap-ffi.git";
    rev = "e3d610b15e8680642c8d4ee844ffcd38ea1a20e4";
    sha256 = "1nzlvq0snp4js2g03gwm8srg9507xsnawzwjm6lsmzlj6zygvbdb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "learn-to-type" = self.lib.mkRacketDerivation rec {
  pname = "learn-to-type";
  src = fetchgit {
    name = "learn-to-type";
    url = "git://github.com/Metaxal/learn-to-type.git";
    rev = "e92730f9e7c1560a9f1dc82fbed6046c4532d167";
    sha256 = "1spvn8vrd9yfj3vamaqa1ljm060kjnzc3j5qr9rhxgip33g9kjjh";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."images-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "left-pad" = self.lib.mkRacketDerivation rec {
  pname = "left-pad";
  src = fetchgit {
    name = "left-pad";
    url = "git://github.com/bennn/racket-left-pad.git";
    rev = "2b17c398c033cc0cbf3535144860676ca682027d";
    sha256 = "0d61q5mcckw8yxb85b7msma3a0r6vhi1m0gmcv873c2vpqk4d18f";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "leftist-tree" = self.lib.mkRacketDerivation rec {
  pname = "leftist-tree";
  src = fetchgit {
    name = "leftist-tree";
    url = "git://github.com/97jaz/leftist-tree.git";
    rev = "3e4f55aecdd0978f282dde6964f444b5da71ed52";
    sha256 = "0wsaq65mngsagnckrcii7v2dclfxy22fgqj3b5zz7xl32ljdyxav";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."data-enumerate-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lens" = self.lib.mkRacketDerivation rec {
  pname = "lens";
  src = self.lib.extractPath {
    path = "lens";
    src = fetchgit {
    name = "lens";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."base" self."lens-common" self."lens-data" self."lens-lib" self."lens-unstable" self."lens-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lens-common" = self.lib.mkRacketDerivation rec {
  pname = "lens-common";
  src = self.lib.extractPath {
    path = "lens-common";
    src = fetchgit {
    name = "lens-common";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."lens-common+lens-data" self."base" self."fancy-app" self."rackunit-lib" self."reprovide-lang-lib" self."sweet-exp-lib" ];
  circularBuildInputs = [ "lens-common" "lens-data" ];
  reverseCircularBuildInputs = [  ];
  };
  "lens-common+lens-data" = self.lib.mkRacketDerivation rec {
  pname = "lens-common+lens-data";

  extraSrcs = [ self."lens-common".src self."lens-data".src ];
  racketThinBuildInputs = [ self."base" self."fancy-app" self."kw-make-struct-lib" self."rackunit-lib" self."reprovide-lang-lib" self."struct-update-lib" self."sweet-exp-lib" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "lens-common" "lens-data" ];
  };
  "lens-data" = self.lib.mkRacketDerivation rec {
  pname = "lens-data";
  src = self.lib.extractPath {
    path = "lens-data";
    src = fetchgit {
    name = "lens-data";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."lens-common+lens-data" self."base" self."rackunit-lib" self."fancy-app" self."syntax-classes-lib" self."struct-update-lib" self."kw-make-struct-lib" self."reprovide-lang-lib" self."sweet-exp-lib" ];
  circularBuildInputs = [ "lens-common" "lens-data" ];
  reverseCircularBuildInputs = [  ];
  };
  "lens-doc" = self.lib.mkRacketDerivation rec {
  pname = "lens-doc";
  src = self.lib.extractPath {
    path = "lens-doc";
    src = fetchgit {
    name = "lens-doc";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."base" self."lens-lib" self."lens-unstable" self."scribble-lib" self."reprovide-lang-lib" self."jack-scribble-example" self."at-exp-lib" self."doc-coverage" self."racket-doc" self."sweet-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lens-lib" = self.lib.mkRacketDerivation rec {
  pname = "lens-lib";
  src = self.lib.extractPath {
    path = "lens-lib";
    src = fetchgit {
    name = "lens-lib";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."base" self."lens-common" self."lens-data" self."reprovide-lang-lib" self."rackunit-lib" self."sweet-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lens-unstable" = self.lib.mkRacketDerivation rec {
  pname = "lens-unstable";
  src = self.lib.extractPath {
    path = "lens-unstable";
    src = fetchgit {
    name = "lens-unstable";
    url = "git://github.com/jackfirth/lens.git";
    rev = "733db7744921409b69ddc78ae5b23ffaa6b91e37";
    sha256 = "0b1qc6j8bi0mj91afrir6hcxka19g02fs067rv46a372gnsfxqc4";
  };
  };
  racketThinBuildInputs = [ self."base" self."lens-lib" self."reprovide-lang-lib" self."sweet-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "levenshtein" = self.lib.mkRacketDerivation rec {
  pname = "levenshtein";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/levenshtein.zip";
    sha1 = "47882e819e941121e4c1873f907502120ebb4382";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libargon2" = self.lib.mkRacketDerivation rec {
  pname = "libargon2";
  src = self.lib.extractPath {
    path = "libargon2";
    src = fetchgit {
    name = "libargon2";
    url = "git://github.com/Bogdanp/racket-libargon2.git";
    rev = "bca550fc02b32b11c33348bb566da2b0a05d2cec";
    sha256 = "1h4x2xyyh59b5ghrv3jg6f7k5nxpii9mki8h0ahz51fb7zbnjnaj";
  };
  };
  racketThinBuildInputs = [ self."base" self."libargon2-i386-win32" self."libargon2-x86_64-linux" self."libargon2-x86_64-macosx" self."libargon2-x86_64-win32" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libargon2-i386-win32" = self.lib.mkRacketDerivation rec {
  pname = "libargon2-i386-win32";
  src = fetchurl {
    url = "https://racket.defn.io/libargon2-i386-win32-20190702.tar.gz";
    sha1 = "41b81f360512128dab394d0019fea8155679e7be";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libargon2-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "libargon2-x86_64-linux";
  src = fetchurl {
    url = "https://racket.defn.io/libargon2-x86_64-linux-20190702.tar.gz";
    sha1 = "b2ef05b85643c017aadfaec3ce96417fc509ab38";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libargon2-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libargon2-x86_64-macosx";
  src = fetchurl {
    url = "https://racket.defn.io/libargon2-x86_64-macosx-20190702.tar.gz";
    sha1 = "b9029b5c0ac51a7b843df6e8473ea3cbcf08e497";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libargon2-x86_64-win32" = self.lib.mkRacketDerivation rec {
  pname = "libargon2-x86_64-win32";
  src = fetchurl {
    url = "https://racket.defn.io/libargon2-x86_64-win32-20190702.tar.gz";
    sha1 = "eed06b587b276950bfef54a32f6235d12a5100c2";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libgit2" = self.lib.mkRacketDerivation rec {
  pname = "libgit2";
  src = fetchgit {
    name = "libgit2";
    url = "git://github.com/bbusching/libgit2.git";
    rev = "6d6a007543900eb7a6fbbeba55850288665bdde5";
    sha256 = "0cfqhmyi4ci6jl9wgb40mi24qmlw7qv6dmhvdjlgz9d8j7i5an5c";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."libgit2-x86_64-linux-natipkg" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libgit2-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "libgit2-x86_64-linux";
  src = self.lib.extractPath {
    path = "libgit2-x86_64-linux";
    src = fetchgit {
    name = "libgit2-x86_64-linux";
    url = "git://github.com/LiberalArtist/native-libgit2-pkgs.git";
    rev = "cc360a4d87c3b861152d13591e99151544cf3998";
    sha256 = "1i8ijndgysry7izggqmhqyc4n96f5xr38jp32j5gx0dqnq6k8mg0";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libgit2-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "libgit2-x86_64-linux-natipkg";
  src = self.lib.extractPath {
    path = "libgit2-x86_64-linux";
    src = fetchgit {
    name = "libgit2-x86_64-linux-natipkg";
    url = "git://github.com/jbclements/libgit2-x86_64-linux-natipkg.git";
    rev = "800f798d74af301135f6921bbc914097778b8a20";
    sha256 = "1wx8f8ng6jmgk4mrp6p0d47h4l4f98pwbf0z1vm81ry3nvld44b4";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libgit2-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libgit2-x86_64-macosx";
  src = self.lib.extractPath {
    path = "libgit2-x86_64-macosx";
    src = fetchgit {
    name = "libgit2-x86_64-macosx";
    url = "git://github.com/LiberalArtist/native-libgit2-pkgs.git";
    rev = "cc360a4d87c3b861152d13591e99151544cf3998";
    sha256 = "1i8ijndgysry7izggqmhqyc4n96f5xr38jp32j5gx0dqnq6k8mg0";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libkenji" = self.lib.mkRacketDerivation rec {
  pname = "libkenji";
  src = fetchgit {
    name = "libkenji";
    url = "git://github.com/quantum1423/libkenji.git";
    rev = "319a80f51bba4224f87a01e6a368d3a936371f88";
    sha256 = "08ik1szpf19yrh65gkpr2cam9q75pm4zic9y4kbnzxgz9i6d1n50";
  };
  racketThinBuildInputs = [ self."pfds" self."typed-racket-lib" self."base" self."compatibility-lib" self."data-lib" self."srfi-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libnotify" = self.lib.mkRacketDerivation rec {
  pname = "libnotify";
  src = fetchgit {
    name = "libnotify";
    url = "git://github.com/takikawa/racket-libnotify.git";
    rev = "c1112e8095f53dde26da994c5d2025871cec9d12";
    sha256 = "1jygjz6zd3f3pybglc5ljppzbxbpg9vssadpc9wxg934l7qirdr7";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."scribble-lib" self."racket-doc" self."draw-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libopenal-racket" = self.lib.mkRacketDerivation rec {
  pname = "libopenal-racket";
  src = fetchgit {
    name = "libopenal-racket";
    url = "git://github.com/lehitoskin/libopenal-racket.git";
    rev = "30ce8d3f2e225b65d0502a0c4feb75e1dea35cc6";
    sha256 = "0x39z2yw7kdqhx0i0jdd9l1qpnvjn2x4iqprac1qswy8zy6vn4s6";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsass-i386-win32" = self.lib.mkRacketDerivation rec {
  pname = "libsass-i386-win32";
  src = fetchurl {
    url = "https://racket.defn.io/libsass-i386-win32-3.6.1.tar.gz";
    sha1 = "bd5b9b3067a712591975f3554456ae0eb53504b2";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsass-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "libsass-x86_64-linux";
  src = fetchurl {
    url = "https://racket.defn.io/libsass-x86_64-linux-3.6.1.tar.gz";
    sha1 = "d896dac88916c119a4cebe2c3c5aed2094e65118";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsass-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libsass-x86_64-macosx";
  src = fetchurl {
    url = "https://racket.defn.io/libsass-x86_64-macosx-3.6.1.tar.gz";
    sha1 = "6eccf0f6125691684932ee67e94e8a8ece7317b4";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsass-x86_64-win32" = self.lib.mkRacketDerivation rec {
  pname = "libsass-x86_64-win32";
  src = fetchurl {
    url = "https://racket.defn.io/libsass-x86_64-win32-3.6.1.tar.gz";
    sha1 = "ccdc5db04ee418049320626a736e588f28e2da16";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libscrypt" = self.lib.mkRacketDerivation rec {
  pname = "libscrypt";
  src = fetchgit {
    name = "libscrypt";
    url = "git://github.com/mordae/racket-libscrypt.git";
    rev = "544c692f6d492275002d55fc933049e4abff56d8";
    sha256 = "0fagb1871a89rxvjlj4mazz41cpq5cb010n5ffh7r2iq93p4bb1g";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."unstable-lib" self."racket-doc" self."unstable-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libserialport" = self.lib.mkRacketDerivation rec {
  pname = "libserialport";
  src = fetchgit {
    name = "libserialport";
    url = "git://github.com/mordae/racket-libserialport.git";
    rev = "51f85372a6e51cc3268c4e45c0bef0f89c836b25";
    sha256 = "15g37nkvwlvv9y64m96qhaafx58qf2vdrcgzckq574z6a5x3ryr2";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."mordae" self."typed-racket-lib" self."racket-doc" self."typed-racket-lib" self."typed-racket-doc" self."unstable-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsqlite3-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "libsqlite3-x86_64-linux";
  src = fetchurl {
    url = "https://racket.defn.io/libsqlite3-x86_64-linux-3.29.0.tar.gz";
    sha1 = "90e41391b43f67037c0fe0c4ab96dcad2a4e334f";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsqlite3-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libsqlite3-x86_64-macosx";
  src = fetchurl {
    url = "https://racket.defn.io/libsqlite3-x86_64-macosx-3.29.0.tar.gz";
    sha1 = "88716b3d6ffebc9518e0cd7a7120c128138af1b3";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libtoxcore-racket" = self.lib.mkRacketDerivation rec {
  pname = "libtoxcore-racket";
  src = fetchgit {
    name = "libtoxcore-racket";
    url = "git://github.com/lehitoskin/libtoxcore-racket.git";
    rev = "8baa14d6835ec4371de4ce7aa73237cd509d8f48";
    sha256 = "0r88wv557bkliw2xlzkljyn2vnkqjk7pymq0v35zdiczflrspz50";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libuuid" = self.lib.mkRacketDerivation rec {
  pname = "libuuid";
  src = fetchgit {
    name = "libuuid";
    url = "git://github.com/mordae/racket-libuuid.git";
    rev = "4bead1a3ccfc1714c1c494f8720c764e4f3b182f";
    sha256 = "0gk279gk9cs4jxdpmwdk61mlxplrk94jzzbyfw9mwxzv0l6ngpbh";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-i386-linux" = self.lib.mkRacketDerivation rec {
  pname = "libvid-i386-linux";
  src = self.lib.extractPath {
    path = "libvid-i386-linux";
    src = fetchgit {
    name = "libvid-i386-linux";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-i386-linux-0-2" = self.lib.mkRacketDerivation rec {
  pname = "libvid-i386-linux-0-2";
  src = self.lib.extractPath {
    path = "libvid-i386-linux";
    src = fetchgit {
    name = "libvid-i386-linux-0-2";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-i386-win32" = self.lib.mkRacketDerivation rec {
  pname = "libvid-i386-win32";
  src = self.lib.extractPath {
    path = "libvid-i386-win32";
    src = fetchgit {
    name = "libvid-i386-win32";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-i386-win32-0-2" = self.lib.mkRacketDerivation rec {
  pname = "libvid-i386-win32-0-2";
  src = self.lib.extractPath {
    path = "libvid-i386-win32";
    src = fetchgit {
    name = "libvid-i386-win32-0-2";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-linux";
  src = self.lib.extractPath {
    path = "libvid-x86_64-linux";
    src = fetchgit {
    name = "libvid-x86_64-linux";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-linux-0-2" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-linux-0-2";
  src = self.lib.extractPath {
    path = "libvid-x86_64-linux";
    src = fetchgit {
    name = "libvid-x86_64-linux-0-2";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-macosx";
  src = self.lib.extractPath {
    path = "libvid-x86_64-macosx";
    src = fetchgit {
    name = "libvid-x86_64-macosx";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-macosx-0-2" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-macosx-0-2";
  src = self.lib.extractPath {
    path = "libvid-x86_64-macosx";
    src = fetchgit {
    name = "libvid-x86_64-macosx-0-2";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-win32" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-win32";
  src = self.lib.extractPath {
    path = "libvid-x86_64-win32";
    src = fetchgit {
    name = "libvid-x86_64-win32";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libvid-x86_64-win32-0-2" = self.lib.mkRacketDerivation rec {
  pname = "libvid-x86_64-win32-0-2";
  src = self.lib.extractPath {
    path = "libvid-x86_64-win32";
    src = fetchgit {
    name = "libvid-x86_64-win32-0-2";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libxml2" = self.lib.mkRacketDerivation rec {
  pname = "libxml2";
  src = fetchgit {
    name = "libxml2";
    url = "git://github.com/LiberalArtist/libxml2-ffi.git";
    rev = "34f26243e8f35ae84f248e02dfbd7214ec2c619d";
    sha256 = "1ccda18waf368jp3qq9k8rnjmnjjd8bypcbfavjskcwszip4jcz4";
  };
  racketThinBuildInputs = [ self."base" self."xmllint-win32-x86_64" self."libxml2-x86_64-linux-natipkg" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."rackunit-spec" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libxml2-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "libxml2-x86_64-linux-natipkg";
  src = fetchgit {
    name = "libxml2-x86_64-linux-natipkg";
    url = "git://github.com/LiberalArtist/libxml2-x86_64-linux-natipkg.git";
    rev = "8175b0d1bd6842fb2f1e814f99ad96035e50e734";
    sha256 = "181676p64qzw1xfxa3lzf59cizc5xxh3pbbb6rhkmx9n8shrx1wi";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lindenmayer" = self.lib.mkRacketDerivation rec {
  pname = "lindenmayer";
  src = fetchgit {
    name = "lindenmayer";
    url = "git://github.com/rfindler/lindenmayer.git";
    rev = "e65a139404ef547abd279a9ec9ab7f924a00c1a4";
    sha256 = "05wqbpiky8hhlbp259n34r9xgsdg9yr4gj5cgg2s4xfc62jnikmk";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."drracket-plugin-lib" self."gui-lib" self."htdp-lib" self."parser-tools-lib" self."pict-lib" self."pict3d" self."syntax-color-lib" self."typed-racket-lib" self."math-lib" self."2d-lib" self."rackunit-lib" self."pict-doc" self."racket-doc" self."scribble-lib" self."htdp-doc" self."syntax-color-doc" self."typed-racket-doc" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "linea" = self.lib.mkRacketDerivation rec {
  pname = "linea";
  src = self.lib.extractPath {
    path = "linea";
    src = fetchgit {
    name = "linea";
    url = "git://github.com/willghatch/racket-rash.git";
    rev = "2b33e444472cf777da3017c23a6538245a93d2d6";
    sha256 = "0pjfnbag08fqdf7nd8k6c35dhp2jjmi0a69vg8a4vdvd7cb0v04x";
  };
  };
  racketThinBuildInputs = [ self."base" self."udelim" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "linkeddata" = self.lib.mkRacketDerivation rec {
  pname = "linkeddata";
  src = self.lib.extractPath {
    path = "linkeddata";
    src = fetchgit {
    name = "linkeddata";
    url = "git://github.com/cwebber/racket-linkeddata.git";
    rev = "4d59948bb978d6d0abf06ec4de8eb6b946f5f291";
    sha256 = "068pk94nymnpbb3f5xx7k9jr1dvazn56cfh2w8bknxp1qqf3g029";
  };
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" self."megaparsack" self."crypto" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lipics" = self.lib.mkRacketDerivation rec {
  pname = "lipics";
  src = fetchgit {
    name = "lipics";
    url = "git://github.com/takikawa/lipics-scribble.git";
    rev = "32a8cb9782493e237c25994f70aa7c572d7ea567";
    sha256 = "1r37j9bvlcxdky9h00jdz6m2rfg7igl022ypzaj7q3zvnjb2329n";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" self."sha" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "list-util" = self.lib.mkRacketDerivation rec {
  pname = "list-util";
  src = fetchgit {
    name = "list-util";
    url = "https://gitlab.com/RayRacine/list-util.git";
    rev = "e538fd85b38e7bfcaf2aace75ced7d0183e91073";
    sha256 = "079g1p49yss184hqi9av3lnid48zchf15na0ygavlhbnx8vffxa9";
  };
  racketThinBuildInputs = [ self."typed-racket-more" self."typed-racket-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "list-utils" = self.lib.mkRacketDerivation rec {
  pname = "list-utils";
  src = fetchgit {
    name = "list-utils";
    url = "git://github.com/v-nys/list-utils.git";
    rev = "d364b7d3e508abc4da31d6e600ee201f76d05217";
    sha256 = "15dm33kq62pamm38ly7jqs7dcc3ywdhz38r6v93imymjgczvz9vk";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "literify" = self.lib.mkRacketDerivation rec {
  pname = "literify";
  src = fetchgit {
    name = "literify";
    url = "git://github.com/kflu/literify.git";
    rev = "0c574bc88dc9de870063589cc49a7ad41899fc67";
    sha256 = "0qvw16civ9zcajhcg25mzw0v9bj17d4sdkx49k65g1nvjp65738v";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "live-free-or-die" = self.lib.mkRacketDerivation rec {
  pname = "live-free-or-die";
  src = fetchgit {
    name = "live-free-or-die";
    url = "git://github.com/jeapostrophe/live-free-or-die.git";
    rev = "b6fbe5364c51eb793a7f88fb916e41506b1d519e";
    sha256 = "0h90zfsk75fc1aa8vlm9dph1x40h30wsqqmaab345wj7if2whddy";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "livefrog" = self.lib.mkRacketDerivation rec {
  pname = "livefrog";
  src = fetchgit {
    name = "livefrog";
    url = "git://github.com/ebzzry/livefrog.git";
    rev = "ba9bb8156d9363203ea3454c9b15e3133d043315";
    sha256 = "0m0sq2z8hhhsg6yb8rpqxcnf1d4wv1s029khaykgzw7zxnsl3p9a";
  };
  racketThinBuildInputs = [ self."sxml" self."frog" self."find-parent-dir" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "loci" = self.lib.mkRacketDerivation rec {
  pname = "loci";
  src = fetchgit {
    name = "loci";
    url = "git://github.com/pmatos/racket-loci.git";
    rev = "c03de09a7c0c8c53f071dc1a5873e6fc17a53c48";
    sha256 = "1kph6mdn45infyk8vy9n44spcn1f8agc23pq1f51kykpivadhs43";
  };
  racketThinBuildInputs = [ self."base" self."unix-socket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."unix-socket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "logbook" = self.lib.mkRacketDerivation rec {
  pname = "logbook";
  src = fetchgit {
    name = "logbook";
    url = "git://github.com/tonyg/racket-logbook.git";
    rev = "6772003b5e8663426559d245451b82ec748c07c7";
    sha256 = "080rapi6hbsi8baw3wi1xhawgyfmplaqb5nlak2awcsgdjwkddf8";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."plot-gui-lib" self."plot-lib" self."web-server-lib" self."csv-reading" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "logger" = self.lib.mkRacketDerivation rec {
  pname = "logger";
  src = fetchgit {
    name = "logger";
    url = "git://github.com/BourgondAries/logger.git";
    rev = "a4cb492d14d2e65840818ed4fe169011b30be23a";
    sha256 = "1a25wf88gqvgvb5h0gybqmw1q6rqgkqkhiaap836v29qngisk4fz";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "logo" = self.lib.mkRacketDerivation rec {
  pname = "logo";
  src = fetchgit {
    name = "logo";
    url = "git://github.com/lwhjp/logo.git";
    rev = "2e9f3f7ffb4b8100aeb52943098f150c1cf7441a";
    sha256 = "0kd23zm2m7njiwakbi3fshwa3kd9zq7wkc4vrmrn4q80yg3zq91g";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."math-lib" self."parser-tools-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "loop" = self.lib.mkRacketDerivation rec {
  pname = "loop";
  src = fetchgit {
    name = "loop";
    url = "git://github.com/sorawee/loop.git";
    rev = "3b979523c56d7052cb342f51a72a2e8cd4743c19";
    sha256 = "04kry3rzxq5wapf5si7qj2kcqr2srmb2c8xncs77mqfqjxb8cjyk";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lti-freq-domain-toolbox" = self.lib.mkRacketDerivation rec {
  pname = "lti-freq-domain-toolbox";
  src = fetchgit {
    name = "lti-freq-domain-toolbox";
    url = "git://github.com/iastefan/lti-freq-domain-toolbox.git";
    rev = "46ce7a04c7a6020f6b74655211e852699d505523";
    sha256 = "0qky00q2m3jjqddkp7ypyvpq3n6a93ddbhv5spdmz6vgiv6x2gpy";
  };
  racketThinBuildInputs = [ self."plot-lib" self."base" self."math-lib" self."plot-gui-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lua" = self.lib.mkRacketDerivation rec {
  pname = "lua";
  src = fetchgit {
    name = "lua";
    url = "git://github.com/shawsumma/lure.git";
    rev = "cdfab7a25944b4e3ae452dec2b1999a37ac889c4";
    sha256 = "1zhlsgcgrcjr3dx99f88hmixmbbj0svn83dwhp0ll6sbhrwhhgzg";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lux" = self.lib.mkRacketDerivation rec {
  pname = "lux";
  src = fetchgit {
    name = "lux";
    url = "git://github.com/jeapostrophe/lux.git";
    rev = "f5d7c1276072f9ea4107b3f8a2d049e0b174c7ba";
    sha256 = "0nrc9fzjhi18ib4nkyyjj2rar8h1sxdd1kl8iyvzpw2057wj5r4w";
  };
  racketThinBuildInputs = [ self."draw-lib" self."drracket" self."gui-lib" self."htdp-lib" self."pict-lib" self."base" self."rackunit-lib" self."draw-doc" self."gui-doc" self."htdp-doc" self."pict-doc" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lux-charterm" = self.lib.mkRacketDerivation rec {
  pname = "lux-charterm";
  src = fetchgit {
    name = "lux-charterm";
    url = "git://github.com/jeapostrophe/lux-charterm.git";
    rev = "8d3d7c39c4cf2160f3912fea34996fe0177c78d7";
    sha256 = "0zpdcpb16lb48phyznxavnk2mscxxn39h83gm219fkzgr793w4lm";
  };
  racketThinBuildInputs = [ self."lux" self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lwc2016" = self.lib.mkRacketDerivation rec {
  pname = "lwc2016";
  src = fetchgit {
    name = "lwc2016";
    url = "git://github.com/dfeltey/lwc2016.git";
    rev = "8b8b98a9d9a8a16538176a561a5ebf3c3df84087";
    sha256 = "1i1zqkxi872cq3ig7n61qi9qh1caip2fj7h18g8hylzav0nvf8bi";
  };
  racketThinBuildInputs = [ self."2d-lib" self."base" self."data-lib" self."drracket-plugin-lib" self."drracket-tool-lib" self."gui-lib" self."parser-tools-lib" self."pict-lib" self."rackunit-lib" self."scribble-lib" self."syntax-color-lib" self."draw-lib" self."ppict" self."slideshow-lib" self."unstable-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macro-debugger" = self.lib.mkRacketDerivation rec {
  pname = "macro-debugger";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/macro-debugger.zip";
    sha1 = "38f9d9c20f052a8245c523c91e0d51c22845eb83";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."class-iop-lib" self."compatibility-lib" self."data-lib" self."gui-lib" self."images-lib" self."images-gui-lib" self."parser-tools-lib" self."macro-debugger-text-lib" self."snip-lib" self."draw-lib" self."racket-index" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "macro-debugger-text-lib" = self.lib.mkRacketDerivation rec {
  pname = "macro-debugger-text-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/macro-debugger-text-lib.zip";
    sha1 = "9d2a63e86f106441d6c76a258145ed3c05265ad9";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."class-iop-lib" self."parser-tools-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macrotypes-example" = self.lib.mkRacketDerivation rec {
  pname = "macrotypes-example";
  src = self.lib.extractPath {
    path = "macrotypes-example";
    src = fetchgit {
    name = "macrotypes-example";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macrotypes-lib" = self.lib.mkRacketDerivation rec {
  pname = "macrotypes-lib";
  src = self.lib.extractPath {
    path = "macrotypes-lib";
    src = fetchgit {
    name = "macrotypes-lib";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macrotypes-nonstx" = self.lib.mkRacketDerivation rec {
  pname = "macrotypes-nonstx";
  src = fetchgit {
    name = "macrotypes-nonstx";
    url = "git://github.com/macrotypefunctors/macrotypes-nonstx.git";
    rev = "b3f9839b6f8dcce4bf3fe9c15d5017214300924d";
    sha256 = "0mhylhr08a7a3jivbqb43r5wmj7n957dazpbzi0z5f050n4v81k8";
  };
  racketThinBuildInputs = [ self."base" self."agile" self."rackunit-lib" self."syntax-classes-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macrotypes-test" = self.lib.mkRacketDerivation rec {
  pname = "macrotypes-test";
  src = self.lib.extractPath {
    path = "macrotypes-test";
    src = fetchgit {
    name = "macrotypes-test";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."macrotypes-example" self."rackunit-macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "magenc" = self.lib.mkRacketDerivation rec {
  pname = "magenc";
  src = self.lib.extractPath {
    path = "magenc";
    src = fetchgit {
    name = "magenc";
    url = "https://gitlab.com/dustyweb/magenc.git";
    rev = "f5e011cb3f4fa060623764a4a80860e31ebca9fc";
    sha256 = "15vrhm2f482yc7q4zhmy0mn6cw7gwhsahc4fwr01r9kf49ivas85";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."csexp" self."db-lib" self."gui-lib" self."sql" self."web-server-lib" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "magic-loader" = self.lib.mkRacketDerivation rec {
  pname = "magic-loader";
  src = fetchgit {
    name = "magic-loader";
    url = "git://github.com/thoughtstem/magic-loader.git";
    rev = "ed983737b383bc527e54f6db7044df503baf2a14";
    sha256 = "12g7qz8v4mn4lqyv1i506i5z3v9ccrqafhsfwkql7njrfm2zj99b";
  };
  racketThinBuildInputs = [ self."comm-panel" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "magnolisp" = self.lib.mkRacketDerivation rec {
  pname = "magnolisp";
  src = fetchgit {
    name = "magnolisp";
    url = "git://github.com/bldl/magnolisp.git";
    rev = "191d529486e688e5dda2be677ad8fe3b654e0d4f";
    sha256 = "09814h5qqzi0rnm4w5nwiiq63jg0brmfr3kabxpanin8miymdf88";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."scribble-lib" self."unstable-debug-lib" self."at-exp-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "main-distribution" = self.lib.mkRacketDerivation rec {
  pname = "main-distribution";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/main-distribution.zip";
    sha1 = "cb16cc0d447f21713260584cb77722b781624da4";
  };
  racketThinBuildInputs = [ self."2d" self."algol60" self."at-exp-lib" self."compatibility" self."contract-profile" self."compiler" self."data" self."datalog" self."db" self."deinprogramm" self."draw" self."draw-doc" self."draw-lib" self."drracket" self."drracket-tool" self."eopl" self."errortrace" self."future-visualizer" self."future-visualizer-typed" self."frtime" self."games" self."gui" self."htdp" self."html" self."icons" self."images" self."lazy" self."macro-debugger" self."macro-debugger-text-lib" self."make" self."math" self."mysterx" self."mzcom" self."mzscheme" self."net" self."net-cookies" self."optimization-coach" self."option-contract" self."parser-tools" self."pconvert-lib" self."pict" self."pict-snip" self."picturing-programs" self."plai" self."planet" self."plot" self."preprocessor" self."profile" self."r5rs" self."r6rs" self."racket-doc" self."distributed-places" self."racket-cheat" self."racket-index" self."racket-lib" self."racklog" self."rackunit" self."rackunit-typed" self."readline" self."realm" self."redex" self."sandbox-lib" self."sasl" self."schemeunit" self."scribble" self."serialize-cstruct-lib" self."sgl" self."shell-completion" self."slatex" self."slideshow" self."snip" self."srfi" self."string-constants" self."swindle" self."syntax-color" self."trace" self."typed-racket" self."typed-racket-more" self."unix-socket" self."web-server" self."wxme" self."xrepl" self."ds-store" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "main-distribution-test" = self.lib.mkRacketDerivation rec {
  pname = "main-distribution-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/main-distribution-test.zip";
    sha1 = "0e9fcad10cd7d32d3bab0c16e04a92301def1cfe";
  };
  racketThinBuildInputs = [ self."racket-test" self."racket-test-extra" self."rackunit-test" self."draw-test" self."gui-test" self."db-test" self."htdp-test" self."html-test" self."redex-test" self."drracket-test" self."profile-test" self."srfi-test" self."errortrace-test" self."r6rs-test" self."web-server-test" self."typed-racket-test" self."xrepl-test" self."scribble-test" self."compiler-test" self."compatibility-test" self."data-test" self."net-test" self."net-cookies-test" self."pconvert-test" self."planet-test" self."syntax-color-test" self."images-test" self."plot-test" self."pict-test" self."pict-snip-test" self."math-test" self."racket-benchmarks" self."drracket-tool-test" self."2d-test" self."option-contract-test" self."sasl-test" self."wxme-test" self."unix-socket-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "make" = self.lib.mkRacketDerivation rec {
  pname = "make";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/make.zip";
    sha1 = "03e6037b95ac8c472e8721fc4bf4f283bd4c7d9a";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."cext-lib" self."compiler-lib" self."compatibility-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "make-log-interceptor" = self.lib.mkRacketDerivation rec {
  pname = "make-log-interceptor";
  src = fetchgit {
    name = "make-log-interceptor";
    url = "git://github.com/bennn/make-log-interceptor.git";
    rev = "9fc289c63ac772bf1fbfccfac324fea2845cdba2";
    sha256 = "08ngigmynnwc6h0qv1wvirvzrq3akfwl470v2rl9mc5fgmhjh9a0";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "map-widget" = self.lib.mkRacketDerivation rec {
  pname = "map-widget";
  src = fetchgit {
    name = "map-widget";
    url = "git://github.com/alex-hhh/map-widget.git";
    rev = "211216a3537184660f64c1328975a50d68ce5841";
    sha256 = "1qwdsag7b3mnidi8yl60vmjmhvs7mqkpvi0kh74r1syj58bfb87w";
  };
  racketThinBuildInputs = [ self."draw-lib" self."errortrace-lib" self."gui-lib" self."db-lib" self."math-lib" self."base" self."scribble-lib" self."draw-doc" self."gui-doc" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "margrave" = self.lib.mkRacketDerivation rec {
  pname = "margrave";
  src = fetchgit {
    name = "margrave";
    url = "git://github.com/jbclements/margrave.git";
    rev = "09780169700c463def0d6c66192f3b07048671d8";
    sha256 = "0sbjndhknhdbk7q6kg4zmkk2mic7lmr7y9w12nc4myj1mx70yl9q";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."parser-tools-lib" self."rackunit-lib" self."scheme-lib" self."srfi-lite-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mario" = self.lib.mkRacketDerivation rec {
  pname = "mario";
  src = fetchgit {
    name = "mario";
    url = "git://github.com/mlang/mario.git";
    rev = "4604f58610230176abdde0ffca38c9df77810a49";
    sha256 = "0iv7njr1b6k03mgk5nnjw6j90qd6a8ji0cj6cisk9jndicc5y0gs";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "marionette" = self.lib.mkRacketDerivation rec {
  pname = "marionette";
  src = self.lib.extractPath {
    path = "marionette";
    src = fetchgit {
    name = "marionette";
    url = "git://github.com/Bogdanp/marionette.git";
    rev = "4b287d9b98246208fc63bb146eae55717a4a2e89";
    sha256 = "0xah3ki9h9f09b086r0jdn0hayj9n0jhb9g7p9rqaad0j7lwp7r6";
  };
  };
  racketThinBuildInputs = [ self."marionette-doc" self."marionette-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "marionette-doc" = self.lib.mkRacketDerivation rec {
  pname = "marionette-doc";
  src = self.lib.extractPath {
    path = "marionette-doc";
    src = fetchgit {
    name = "marionette-doc";
    url = "git://github.com/Bogdanp/marionette.git";
    rev = "4b287d9b98246208fc63bb146eae55717a4a2e89";
    sha256 = "0xah3ki9h9f09b086r0jdn0hayj9n0jhb9g7p9rqaad0j7lwp7r6";
  };
  };
  racketThinBuildInputs = [ self."base" self."marionette-lib" self."scribble-lib" self."net-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "marionette-lib" = self.lib.mkRacketDerivation rec {
  pname = "marionette-lib";
  src = self.lib.extractPath {
    path = "marionette-lib";
    src = fetchgit {
    name = "marionette-lib";
    url = "git://github.com/Bogdanp/marionette.git";
    rev = "4b287d9b98246208fc63bb146eae55717a4a2e89";
    sha256 = "0xah3ki9h9f09b086r0jdn0hayj9n0jhb9g7p9rqaad0j7lwp7r6";
  };
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "marionette-test" = self.lib.mkRacketDerivation rec {
  pname = "marionette-test";
  src = self.lib.extractPath {
    path = "marionette-test";
    src = fetchgit {
    name = "marionette-test";
    url = "git://github.com/Bogdanp/marionette.git";
    rev = "4b287d9b98246208fc63bb146eae55717a4a2e89";
    sha256 = "0xah3ki9h9f09b086r0jdn0hayj9n0jhb9g7p9rqaad0j7lwp7r6";
  };
  };
  racketThinBuildInputs = [ self."base" self."marionette-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markdown" = self.lib.mkRacketDerivation rec {
  pname = "markdown";
  src = fetchgit {
    name = "markdown";
    url = "git://github.com/greghendershott/markdown.git";
    rev = "344ce8dec965334f3ca6ce0b05383bf642fb29e9";
    sha256 = "0k7fdymnv1w9f93ji0vi51ff7ybk37ws4lq0j11x0wm448n9jwcl";
  };
  racketThinBuildInputs = [ self."base" self."parsack" self."sandbox-lib" self."scribble-lib" self."srfi-lite-lib" self."threading-lib" self."at-exp-lib" self."html-lib" self."racket-doc" self."rackunit-lib" self."redex-lib" self."scribble-doc" self."sexp-diff" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markdown-ng" = self.lib.mkRacketDerivation rec {
  pname = "markdown-ng";
  src = fetchgit {
    name = "markdown-ng";
    url = "git://github.com/pmatos/markdown-ng.git";
    rev = "bbafa81f727cc043a20c9b4f447e7a3566f302a5";
    sha256 = "174y6fbl91q6xm0pfl5j4qrmag8hzv62psjfmsxvr6729g9gd157";
  };
  racketThinBuildInputs = [ self."base" self."parsack" self."sandbox-lib" self."scribble-lib" self."srfi-lite-lib" self."threading-lib" self."at-exp-lib" self."html-lib" self."racket-doc" self."rackunit-lib" self."redex-lib" self."scribble-doc" self."sexp-diff" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markparam" = self.lib.mkRacketDerivation rec {
  pname = "markparam";
  src = self.lib.extractPath {
    path = "markparam";
    src = fetchgit {
    name = "markparam";
    url = "git://github.com/jeapostrophe/markparam.git";
    rev = "f6393494334318ef497606001f2e83bab2c8c15d";
    sha256 = "1fj9xn8s5b1n3qz881qibj29dhzbyjgkj2g0yxaav02580qgvxs0";
  };
  };
  racketThinBuildInputs = [ self."markparam-lib" self."markparam-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markparam-doc" = self.lib.mkRacketDerivation rec {
  pname = "markparam-doc";
  src = self.lib.extractPath {
    path = "markparam-doc";
    src = fetchgit {
    name = "markparam-doc";
    url = "git://github.com/jeapostrophe/markparam.git";
    rev = "f6393494334318ef497606001f2e83bab2c8c15d";
    sha256 = "1fj9xn8s5b1n3qz881qibj29dhzbyjgkj2g0yxaav02580qgvxs0";
  };
  };
  racketThinBuildInputs = [ self."base" self."markparam-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markparam-lib" = self.lib.mkRacketDerivation rec {
  pname = "markparam-lib";
  src = self.lib.extractPath {
    path = "markparam-lib";
    src = fetchgit {
    name = "markparam-lib";
    url = "git://github.com/jeapostrophe/markparam.git";
    rev = "f6393494334318ef497606001f2e83bab2c8c15d";
    sha256 = "1fj9xn8s5b1n3qz881qibj29dhzbyjgkj2g0yxaav02580qgvxs0";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markparam-test" = self.lib.mkRacketDerivation rec {
  pname = "markparam-test";
  src = self.lib.extractPath {
    path = "markparam-test";
    src = fetchgit {
    name = "markparam-test";
    url = "git://github.com/jeapostrophe/markparam.git";
    rev = "f6393494334318ef497606001f2e83bab2c8c15d";
    sha256 = "1fj9xn8s5b1n3qz881qibj29dhzbyjgkj2g0yxaav02580qgvxs0";
  };
  };
  racketThinBuildInputs = [ self."base" self."markparam-lib" self."racket-index" self."eli-tester" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "match-count" = self.lib.mkRacketDerivation rec {
  pname = "match-count";
  src = fetchgit {
    name = "match-count";
    url = "git://github.com/samth/match-count.git";
    rev = "99dc72c1dc254602d92d46f12552b95fab6f2ee5";
    sha256 = "0918y8wfvyvkmmir7kcjwfhy8j3x1mqmc069ls01cjkmbha288ph";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "match-plus" = self.lib.mkRacketDerivation rec {
  pname = "match-plus";
  src = fetchgit {
    name = "match-plus";
    url = "git://github.com/lexi-lambda/racket-match-plus.git";
    rev = "cd72471c582f5c20ec35a96fa08936f4f3fd6c47";
    sha256 = "05hwcpjh8ybd86izsq5fx292nm842c1gb5zlrlpxj3y3s6hg618d";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "match-string" = self.lib.mkRacketDerivation rec {
  pname = "match-string";
  src = fetchgit {
    name = "match-string";
    url = "git://github.com/AlexKnauth/match-string.git";
    rev = "90a1062d6bf0e34d1b11f27e0d5079803fbb2002";
    sha256 = "1ar7j7ri5hqk0d95c4mxxmgakhzrdj8fs5d53gfrky89ap692faf";
  };
  racketThinBuildInputs = [ self."base" self."anaphoric" self."srfi-lite-lib" self."rackunit-lib" self."htdp-lib" self."racket-doc" self."scribble-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math" = self.lib.mkRacketDerivation rec {
  pname = "math";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math.zip";
    sha1 = "0e2e1bdd2f8e85553a6b6cb4dba3d7313ec8196b";
  };
  racketThinBuildInputs = [ self."math-lib" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-doc" = self.lib.mkRacketDerivation rec {
  pname = "math-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-doc.zip";
    sha1 = "13b244aba872155767af054732e9dc6aa4ca6f4c";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."at-exp-lib" self."math-lib" self."plot-gui-lib" self."sandbox-lib" self."scribble-lib" self."typed-racket-lib" self."2d-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "math-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-i386-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-i386-macosx.zip";
    sha1 = "3282fea3fdb24993d73e84d553ad887976a2b92d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-lib" = self.lib.mkRacketDerivation rec {
  pname = "math-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-lib.zip";
    sha1 = "665da6fb2e4468b5de53106647337f272edd9980";
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" self."typed-racket-lib" self."typed-racket-more" self."math-i386-macosx" self."math-x86_64-macosx" self."math-ppc-macosx" self."math-win32-i386" self."math-win32-x86_64" self."math-x86_64-linux-natipkg" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-ppc-macosx.zip";
    sha1 = "1f352117b14fc4dbd4f93ffc13dd30aa5fc1378c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-test" = self.lib.mkRacketDerivation rec {
  pname = "math-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-test.zip";
    sha1 = "0df60f89a0a377e88a51429f45d1b635a30edbb6";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."racket-test" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "math-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-win32-i386.zip";
    sha1 = "948c205581db3e11e66a3163ec35db7eabdfd279";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "math-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-win32-x86_64.zip";
    sha1 = "c898b2fd0aa707fc16c42275a40dd8d711fa541e";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "math-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-x86_64-linux-natipkg.zip";
    sha1 = "d9d30db70541df1b369eb31006c58e104d707bb3";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-x86_64-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/math-x86_64-macosx.zip";
    sha1 = "6520d02ae5a1e6d96526f7f1182b023ba277ee72";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mboxrd-read" = self.lib.mkRacketDerivation rec {
  pname = "mboxrd-read";
  src = fetchgit {
    name = "mboxrd-read";
    url = "git://github.com/jbclements/mboxrd-read.git";
    rev = "fe1fa607c8efabe267f30a8c9a321e823c775dbd";
    sha256 = "1z06slp6h6rcvq74pjls9m9rjhin1skch1nsa6ak2rwbnmd8f006";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."rackunit-lib" self."scribble-lib" self."net-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mcfly" = self.lib.mkRacketDerivation rec {
  pname = "mcfly";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/mcfly.zip";
    sha1 = "e670b083eefe6ac27c23cc9423bac0f31720d58c";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "measures" = self.lib.mkRacketDerivation rec {
  pname = "measures";
  src = fetchgit {
    name = "measures";
    url = "git://github.com/Metaxal/measures.git";
    rev = "f75e2361a767cab6fb662c761cc93d15b00c964a";
    sha256 = "183vsj914zkvpnbrfk4s8bid4rlpi3c9z40r9y06zmryi9c8rins";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "measures-with-dimensions" = self.lib.mkRacketDerivation rec {
  pname = "measures-with-dimensions";
  src = fetchgit {
    name = "measures-with-dimensions";
    url = "git://github.com/AlexKnauth/measures-with-dimensions.git";
    rev = "c64cdb64d4b67660b28916749241a9fc696e8a8c";
    sha256 = "1rhz93r3cak7dinr26wwg6pdbha5wxps0c6fsz8wgsbxjgqyq5zx";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."threading" self."math-lib" self."htdp-lib" self."unstable-lib" self."sweet-exp" self."reprovide-lang" self."predicates" self."colon-match" self."scribble-lib" self."rackunit-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" self."typed-racket-doc" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mediafile" = self.lib.mkRacketDerivation rec {
  pname = "mediafile";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/mediafile.zip";
    sha1 = "3d87ac5b4e35a527d7f9263af40e014d1400edb7";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."canonicalize-path" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "medic" = self.lib.mkRacketDerivation rec {
  pname = "medic";
  src = fetchgit {
    name = "medic";
    url = "git://github.com/lixiangqi/medic.git";
    rev = "0920090d3c77d6873b8481841622a5f2d13a732c";
    sha256 = "01as5556dkrxxfj3awff3a4d7z5hj8vnx5p182hmk5vmnlq5sj9w";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."scheme-lib" self."compatibility-lib" self."gui-lib" self."images-lib" self."pict-lib" self."draw-lib" self."racket-doc" self."scribble-lib" self."redex-pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "megaparsack" = self.lib.mkRacketDerivation rec {
  pname = "megaparsack";
  src = self.lib.extractPath {
    path = "megaparsack";
    src = fetchgit {
    name = "megaparsack";
    url = "git://github.com/lexi-lambda/megaparsack.git";
    rev = "45168f1833ff9002016c3a3234e90315015c0cee";
    sha256 = "1afplsa19s5gsbnk3yzxdsc2yi5z3l819zv5zc8l9qkfbqn94244";
  };
  };
  racketThinBuildInputs = [ self."base" self."megaparsack-lib" self."megaparsack-doc" self."megaparsack-parser" self."megaparsack-parser-tools" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "megaparsack-doc" = self.lib.mkRacketDerivation rec {
  pname = "megaparsack-doc";
  src = self.lib.extractPath {
    path = "megaparsack-doc";
    src = fetchgit {
    name = "megaparsack-doc";
    url = "git://github.com/lexi-lambda/megaparsack.git";
    rev = "45168f1833ff9002016c3a3234e90315015c0cee";
    sha256 = "1afplsa19s5gsbnk3yzxdsc2yi5z3l819zv5zc8l9qkfbqn94244";
  };
  };
  racketThinBuildInputs = [ self."base" self."functional-doc" self."functional-lib" self."megaparsack-lib" self."megaparsack-parser-tools" self."parser-tools-doc" self."parser-tools-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "megaparsack-lib" = self.lib.mkRacketDerivation rec {
  pname = "megaparsack-lib";
  src = self.lib.extractPath {
    path = "megaparsack-lib";
    src = fetchgit {
    name = "megaparsack-lib";
    url = "git://github.com/lexi-lambda/megaparsack.git";
    rev = "45168f1833ff9002016c3a3234e90315015c0cee";
    sha256 = "1afplsa19s5gsbnk3yzxdsc2yi5z3l819zv5zc8l9qkfbqn94244";
  };
  };
  racketThinBuildInputs = [ self."base" self."curly-fn-lib" self."functional-lib" self."match-plus" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "megaparsack-parser" = self.lib.mkRacketDerivation rec {
  pname = "megaparsack-parser";
  src = self.lib.extractPath {
    path = "megaparsack-parser";
    src = fetchgit {
    name = "megaparsack-parser";
    url = "git://github.com/lexi-lambda/megaparsack.git";
    rev = "45168f1833ff9002016c3a3234e90315015c0cee";
    sha256 = "1afplsa19s5gsbnk3yzxdsc2yi5z3l819zv5zc8l9qkfbqn94244";
  };
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."curly-fn-lib" self."functional-lib" self."megaparsack-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "megaparsack-parser-tools" = self.lib.mkRacketDerivation rec {
  pname = "megaparsack-parser-tools";
  src = self.lib.extractPath {
    path = "megaparsack-parser-tools";
    src = fetchgit {
    name = "megaparsack-parser-tools";
    url = "git://github.com/lexi-lambda/megaparsack.git";
    rev = "45168f1833ff9002016c3a3234e90315015c0cee";
    sha256 = "1afplsa19s5gsbnk3yzxdsc2yi5z3l819zv5zc8l9qkfbqn94244";
  };
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" self."megaparsack-lib" self."parser-tools-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "memcached" = self.lib.mkRacketDerivation rec {
  pname = "memcached";
  src = fetchgit {
    name = "memcached";
    url = "git://github.com/jeapostrophe/memcached.git";
    rev = "465d1bfc700140232c4abd0b854d807740895237";
    sha256 = "1xcwykqx4qsfl2k3imr147dpg7jlvx538q7ycq02c3y326f5m7vd";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "memo" = self.lib.mkRacketDerivation rec {
  pname = "memo";
  src = fetchgit {
    name = "memo";
    url = "git://github.com/BourgondAries/memo.git";
    rev = "3ecfa4ad20c38ce97fedaed848d08348e92c56d3";
    sha256 = "02sdi28c2qvyqsx8dpf9wsnlxs42ahvxrkrqqwym0kh0qvl5irxp";
  };
  racketThinBuildInputs = [ self."base" self."finalizer" self."nested-hash" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."thread-utils" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "memoize" = self.lib.mkRacketDerivation rec {
  pname = "memoize";
  src = fetchgit {
    name = "memoize";
    url = "git://github.com/jbclements/memoize.git";
    rev = "9cdbf7512b8a531b1b26ffc02160aa9e8125f2ed";
    sha256 = "07w8y0pfhikmj12raq12d7z8kmg9n6lp5npp0lvhlaanp1hffwhh";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "metapict" = self.lib.mkRacketDerivation rec {
  pname = "metapict";
  src = fetchgit {
    name = "metapict";
    url = "git://github.com/soegaard/metapict.git";
    rev = "3946eee0193eaf56da89b937ce7dd34e7db3b334";
    sha256 = "1x8aw6r1a75frxdqx5sya95rkyvs9fhyz6vhij3ghc2cmkba7dyz";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."math-lib" self."gui-lib" self."parser-tools-lib" self."pict-lib" self."slideshow-lib" self."srfi-lite-lib" self."ppict" self."htdp-lib" self."compatibility-lib" self."graph-lib" self."plot-gui-lib" self."plot-lib" self."rackunit-lib" self."unstable-latent-contract-lib" self."unstable-parameter-group-lib" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."draw-doc" self."pict-doc" self."racket-poppler" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mf-apply" = self.lib.mkRacketDerivation rec {
  pname = "mf-apply";
  src = fetchgit {
    name = "mf-apply";
    url = "git://github.com/bennn/mf-apply.git";
    rev = "e7b079c172bd20035a48d50af56e766186568057";
    sha256 = "0xf808hahyar5qkq84h9sn5cb2cs2zfj35yzh4rr565cl30628zg";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."redex-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mic1" = self.lib.mkRacketDerivation rec {
  pname = "mic1";
  src = self.lib.extractPath {
    path = "rkt";
    src = fetchgit {
    name = "mic1";
    url = "git://github.com/jeapostrophe/mic1.git";
    rev = "e985f4698f005049643998d28f8173e821acdb6b";
    sha256 = "04js0h0shlsrdixd8v7n87d1z5x4fm1904hjrkymd7wxpf3vwdwz";
  };
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."readline-lib" self."racket-doc" self."scribble-lib" self."chk" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "midi-readwrite" = self.lib.mkRacketDerivation rec {
  pname = "midi-readwrite";
  src = fetchgit {
    name = "midi-readwrite";
    url = "git://github.com/jbclements/midi-readwrite.git";
    rev = "92953cfef013e2c654e8f972b5d55f0da220fae4";
    sha256 = "0y3frsdyb3r8i2f7pbkmrk2r1k01samrfz3s4vymwwr13yqsqby0";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "minetest" = self.lib.mkRacketDerivation rec {
  pname = "minetest";
  src = fetchgit {
    name = "minetest";
    url = "git://github.com/thoughtstem/minetest.git";
    rev = "74ba2d02511e96bfc477ab6db4937d1732bd1e2b";
    sha256 = "1bicjwxxg673fbbxqx8314ij55ln4xgqqn17362lwqn9g6jynvik";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "minikanren" = self.lib.mkRacketDerivation rec {
  pname = "minikanren";
  src = fetchgit {
    name = "minikanren";
    url = "git://github.com/takikawa/minikanren.git";
    rev = "659404d009e9cec9695805f4d4465447796a663a";
    sha256 = "1bjv0adc9clfw97r3rpav5jmfjlbjj13nv4psfrvsl7inhw5pdf0";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "minikanren-ee" = self.lib.mkRacketDerivation rec {
  pname = "minikanren-ee";
  src = fetchgit {
    name = "minikanren-ee";
    url = "git://github.com/michaelballantyne/minikanren-ee.git";
    rev = "e07c2b99cb3a49fd624bb8249a16879ff23a4f8c";
    sha256 = "0620ybfbwarmyb7frdw3kr9zi57k668swkvfipzkkmhbj59p56ah";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."faster-minikanren" self."ee-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "minimal-doclang" = self.lib.mkRacketDerivation rec {
  pname = "minimal-doclang";
  src = fetchgit {
    name = "minimal-doclang";
    url = "git://github.com/zyrolasting/minimal-doclang.git";
    rev = "9ea1cf0e7136f88189e76f47810a487c9ad37a5b";
    sha256 = "125vapw5kcckcnfy3bwf309d7kf9wdhm6nbwfayc1c87dw9sid00";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "minipascal" = self.lib.mkRacketDerivation rec {
  pname = "minipascal";
  src = fetchgit {
    name = "minipascal";
    url = "git://github.com/soegaard/minipascal.git";
    rev = "6c028051ba9c151c5b6e8fddd6c2442c1abb0601";
    sha256 = "15vk03nqa7mngns0smzrdmcbiiay7vh6z19gn0ad82kwpm1zhf0b";
  };
  racketThinBuildInputs = [ self."ragg" self."base" self."parser-tools-lib" self."base" self."parser-tools-lib" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "misc1" = self.lib.mkRacketDerivation rec {
  pname = "misc1";
  src = fetchgit {
    name = "misc1";
    url = "git://github.com/mordae/racket-misc1.git";
    rev = "92d66c9c2c5fefe4762acc221b69c5e716a6873d";
    sha256 = "0zk7afqsxcxgq223a4hb854nqqkf1mzclb3b8idsgmjcm2vryr8l";
  };
  racketThinBuildInputs = [ self."base" self."unstable-lib" self."racket-doc" self."unstable-lib" self."unstable-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mischief" = self.lib.mkRacketDerivation rec {
  pname = "mischief";
  src = fetchgit {
    name = "mischief";
    url = "git://github.com/carl-eastlund/mischief.git";
    rev = "c6f95a774b60950cabd7238e639f7e5f0d8737cd";
    sha256 = "15kvjdk2v8723pz3ph2iyl0wyx4kr259idi62rmbix6037qczi1g";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."macro-debugger" self."macro-debugger-text-lib" self."pconvert-lib" self."sandbox-lib" self."scribble-lib" self."srfi-lib" self."srfi-lite-lib" self."compatibility-doc" self."data-doc" self."racket-doc" self."scribble-doc" self."racket-index" self."rackunit-gui" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mischief-dev" = self.lib.mkRacketDerivation rec {
  pname = "mischief-dev";
  src = fetchgit {
    name = "mischief-dev";
    url = "git://github.com/carl-eastlund/mischief.git";
    rev = "ce58c3170240f12297e2f98475f53c9514225825";
    sha256 = "15kvjdk2v8723pz3ph2iyl0wyx4kr259idi62rmbix6037qczi1g";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."macro-debugger" self."macro-debugger-text-lib" self."pconvert-lib" self."sandbox-lib" self."scribble-lib" self."srfi-lib" self."srfi-lite-lib" self."compatibility-doc" self."data-doc" self."racket-doc" self."scribble-doc" self."racket-index" self."rackunit-gui" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mm" = self.lib.mkRacketDerivation rec {
  pname = "mm";
  src = fetchgit {
    name = "mm";
    url = "git://github.com/jeapostrophe/mm.git";
    rev = "9b733818036f340181cb5f5d5083e481f4709cd9";
    sha256 = "0qgpkzblp7kiw9b94li4hibz6zn91lin4fc9pylk89n9wsg6ainj";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."data-lib" self."rackunit-chk" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mmap" = self.lib.mkRacketDerivation rec {
  pname = "mmap";
  src = fetchgit {
    name = "mmap";
    url = "git://github.com/samth/mmap.git";
    rev = "4d75782ebac990ae85a2b456f9d138cb666deed5";
    sha256 = "1m5blkzxlcdli6bxalvrscjkbk11fsxipqabjz2i7r32pvdahafq";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mobilpay" = self.lib.mkRacketDerivation rec {
  pname = "mobilpay";
  src = fetchgit {
    name = "mobilpay";
    url = "git://github.com/Bogdanp/mobilpay.git";
    rev = "0c75ab1a28c834035fb1d661e3e0390338b9f34a";
    sha256 = "0yy24srhqk6nm3grnxjskvskr764hhvi6faqif999vsyj0pnd39j";
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."gregor-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mock" = self.lib.mkRacketDerivation rec {
  pname = "mock";
  src = self.lib.extractPath {
    path = "mock";
    src = fetchgit {
    name = "mock";
    url = "git://github.com/jackfirth/racket-mock.git";
    rev = "1a27bb7a1444effc034bf8b2df4ba1845f51478f";
    sha256 = "1d7y7f08ys0lg3m89zy66whkzpd7vdn4xhkp5nv99vg0pdl2zilm";
  };
  };
  racketThinBuildInputs = [ self."arguments" self."base" self."fancy-app" self."reprovide-lang" self."racket-doc" self."scribble-lib" self."sweet-exp" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mock-rackunit" = self.lib.mkRacketDerivation rec {
  pname = "mock-rackunit";
  src = self.lib.extractPath {
    path = "mock-rackunit";
    src = fetchgit {
    name = "mock-rackunit";
    url = "git://github.com/jackfirth/racket-mock.git";
    rev = "1a27bb7a1444effc034bf8b2df4ba1845f51478f";
    sha256 = "1d7y7f08ys0lg3m89zy66whkzpd7vdn4xhkp5nv99vg0pdl2zilm";
  };
  };
  racketThinBuildInputs = [ self."base" self."mock" self."rackunit-lib" self."racket-doc" self."rackunit-doc" self."scribble-lib" self."sweet-exp" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mockfighter" = self.lib.mkRacketDerivation rec {
  pname = "mockfighter";
  src = fetchgit {
    name = "mockfighter";
    url = "git://github.com/eu90h/mockfighter.git";
    rev = "63906eff874e90644725dbff5365889d959e2294";
    sha256 = "0682hmmd04r3a90d2510mhf092sa6nzvzq9qgclgp4hdp7324pk7";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."stockfighter-racket" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mode-lambda" = self.lib.mkRacketDerivation rec {
  pname = "mode-lambda";
  src = fetchgit {
    name = "mode-lambda";
    url = "git://github.com/jeapostrophe/mode-lambda.git";
    rev = "64b5ae81f457ded7664458cd9935ce7d3ebfc449";
    sha256 = "0pv2fbx00wm0kls08lva84z72farlrvxpnikb7gn61c823xgpg2d";
  };
  racketThinBuildInputs = [ self."gui-lib" self."scheme-lib" self."web-server-lib" self."lux" self."reprovide-lang-lib" self."base" self."srfi-lite-lib" self."draw-lib" self."opengl" self."htdp-lib" self."pict-lib" self."draw-lib" self."draw-doc" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "molis-hai" = self.lib.mkRacketDerivation rec {
  pname = "molis-hai";
  src = fetchgit {
    name = "molis-hai";
    url = "git://github.com/jbclements/molis-hai.git";
    rev = "6a335ec73c144f9d8ac538752ca8e6fd0b3b3cce";
    sha256 = "04v7s5y5idiwagb6q7gc13zmjrp4zxyrkmr7qdhx335zzqzzk3lw";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."pfds" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "monad" = self.lib.mkRacketDerivation rec {
  pname = "monad";
  src = fetchgit {
    name = "monad";
    url = "git://github.com/tonyg/racket-monad.git";
    rev = "e61a1b940cac3e85a0408d4463c9324bb3615413";
    sha256 = "1viw97g2l0faplyky4rql6hsahkhx66gy8h4hz7j05xb7kmki47s";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mongodb" = self.lib.mkRacketDerivation rec {
  pname = "mongodb";
  src = fetchgit {
    name = "mongodb";
    url = "git://github.com/jeapostrophe/mongodb.git";
    rev = "4fbeb1a577ff9a1b8274045a5741d6670d555ac7";
    sha256 = "1jlynyrny2jdjrg5w03ypm1gbsvc3dqdwjp34rnn02p4j8rjxy0g";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."srfi-lite-lib" self."eli-tester" self."racket-doc" self."scribble-lib" self."srfi-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "monitors" = self.lib.mkRacketDerivation rec {
  pname = "monitors";
  src = fetchgit {
    name = "monitors";
    url = "git://github.com/howell/monitors.git";
    rev = "928a1b27b15ad46eb0f715b3bccfe06b437edf30";
    sha256 = "0043biv8lkwy22p3421y5ch10mp4mrs5mrnmg6mjxs5glnf13alf";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "monotonic" = self.lib.mkRacketDerivation rec {
  pname = "monotonic";
  src = fetchgit {
    name = "monotonic";
    url = "git://github.com/Bogdanp/racket-monotonic.git";
    rev = "46452c05a9cb8a459c07f58dc39626d2159165d3";
    sha256 = "02f9s0m4q8cgaba55iiyi2nhgghzmp51yxvnl0q52r81w4w9q3g9";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mordae" = self.lib.mkRacketDerivation rec {
  pname = "mordae";
  src = fetchgit {
    name = "mordae";
    url = "git://github.com/mordae/racket-mordae.git";
    rev = "01d86a7453241f438b01a37f991a28feeb43df8e";
    sha256 = "1kvqgk906mzbmijbr9cxwmski7dgw2bz3dnd65vhci1kg0cvppcy";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "morsel-doc" = self.lib.mkRacketDerivation rec {
  pname = "morsel-doc";
  src = self.lib.extractPath {
    path = "morsel-doc";
    src = fetchgit {
    name = "morsel-doc";
    url = "git://github.com/default-kramer/morsel.git";
    rev = "124a29f0e12f69503dcae9437356fd9c21fefa36";
    sha256 = "19hz2cx5bf837v40b7q2zbr1i0nz21gfpzgbqfszb0ybars33cf8";
  };
  };
  racketThinBuildInputs = [ self."base" self."morsel-lib" self."scribble-lib" self."racket-doc" self."doc-coverage" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "morsel-lib" = self.lib.mkRacketDerivation rec {
  pname = "morsel-lib";
  src = self.lib.extractPath {
    path = "morsel-lib";
    src = fetchgit {
    name = "morsel-lib";
    url = "git://github.com/default-kramer/morsel.git";
    rev = "124a29f0e12f69503dcae9437356fd9c21fefa36";
    sha256 = "19hz2cx5bf837v40b7q2zbr1i0nz21gfpzgbqfszb0ybars33cf8";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mosquitto-ffi" = self.lib.mkRacketDerivation rec {
  pname = "mosquitto-ffi";
  src = fetchgit {
    name = "mosquitto-ffi";
    url = "git://github.com/bartbes/mosquitto-racket.git";
    rev = "03b969b3f8806f7cfeb31b281981628fe8e2ca8b";
    sha256 = "1cxa8vw9wm3dq5f3zs9fwl9qqsm433xxw75s5pnjg79q4ypbqchj";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mred-designer" = self.lib.mkRacketDerivation rec {
  pname = "mred-designer";
  src = fetchgit {
    name = "mred-designer";
    url = "git://github.com/Metaxal/MrEd-Designer.git";
    rev = "c025195ac9a66b57a910a23270120fa820ebdee3";
    sha256 = "05z2izvlfapfikwh0dr7xdrmlbbk5sy7za6fljlc16xp3mp1c2ww";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."net-lib" self."planet-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "msgpack" = self.lib.mkRacketDerivation rec {
  pname = "msgpack";
  src = self.lib.extractPath {
    path = "msgpack";
    src = fetchgit {
    name = "msgpack";
    url = "https://gitlab.com/HiPhish/MsgPack.rkt.git";
    rev = "64a60986b149703ff9436877da1dd3e86c6e4094";
    sha256 = "0hdngx7hdkxbc1rakch8q58am7vwkd4is3zkx74y557an61pr1ql";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."quickcheck" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "msgpack-rpc" = self.lib.mkRacketDerivation rec {
  pname = "msgpack-rpc";
  src = fetchgit {
    name = "msgpack-rpc";
    url = "git://github.com/wbthomason/msgpack-rpc-racket.git";
    rev = "e605bf9d822a3995745d3739b23fd89c7db859e5";
    sha256 = "1jnnc1bn25jg64dlzadka3azcn402f4ylp8z5zsv2dc1r010af5m";
  };
  racketThinBuildInputs = [ self."base" self."msgpack" self."unix-socket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mud" = self.lib.mkRacketDerivation rec {
  pname = "mud";
  src = fetchgit {
    name = "mud";
    url = "https://gitlab.com/emsenn/racket-mud.git";
    rev = "757bebf058e0b005509161d214da9909dbce92b9";
    sha256 = "05dwnc19knncd25mk90r8dawxfnrnpmjxg982xmi2qrn1dj51n79";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multi-file-lang" = self.lib.mkRacketDerivation rec {
  pname = "multi-file-lang";
  src = fetchgit {
    name = "multi-file-lang";
    url = "git://github.com/AlexKnauth/multi-file-lang.git";
    rev = "0975cc27e0003050597da7d9f1fc5e9eac341fc7";
    sha256 = "0fljv667z111mmrdyfcnd63kp41bmczjybxwbr6dhzg8iig1i5kx";
  };
  racketThinBuildInputs = [ self."base" self."lang-file" self."rackunit-lib" self."typed-racket-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multi-id" = self.lib.mkRacketDerivation rec {
  pname = "multi-id";
  src = fetchgit {
    name = "multi-id";
    url = "git://github.com/jsmaniac/multi-id.git";
    rev = "d0e61ac7e9a18a079f5671075604c68abd43b1ef";
    sha256 = "16dfl0vjxd9l9z4hmn2728v86cd2n7m1z568pwxrzij88160m18x";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."phc-toolkit" self."type-expander" self."scribble-lib" self."hyper-literate" self."scribble-lib" self."racket-doc" self."scribble-enhanced" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multicolumn" = self.lib.mkRacketDerivation rec {
  pname = "multicolumn";
  src = fetchgit {
    name = "multicolumn";
    url = "git://github.com/Kalimehtar/multicolumn.git";
    rev = "916e9acca5ccf56b319bf5e641fac483ed60eac9";
    sha256 = "1bhd8avny32x8a4jbzxhly56x40k4v2nf7yksr1nf3ak3hw4ma2c";
  };
  racketThinBuildInputs = [ self."base" self."stretchable-snip" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multimethod" = self.lib.mkRacketDerivation rec {
  pname = "multimethod";
  src = self.lib.extractPath {
    path = "multimethod";
    src = fetchgit {
    name = "multimethod";
    url = "git://github.com/lexi-lambda/racket-multimethod.git";
    rev = "8a0903ebaedd919971c382eeb785f05080c7a8d6";
    sha256 = "0jbmvs6q14f58hfi9qvz8g4ndq13ybyy80y375w7455s7y3w3af0";
  };
  };
  racketThinBuildInputs = [ self."base" self."multimethod-lib" self."multimethod-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multimethod-doc" = self.lib.mkRacketDerivation rec {
  pname = "multimethod-doc";
  src = self.lib.extractPath {
    path = "multimethod-doc";
    src = fetchgit {
    name = "multimethod-doc";
    url = "git://github.com/lexi-lambda/racket-multimethod.git";
    rev = "8a0903ebaedd919971c382eeb785f05080c7a8d6";
    sha256 = "0jbmvs6q14f58hfi9qvz8g4ndq13ybyy80y375w7455s7y3w3af0";
  };
  };
  racketThinBuildInputs = [ self."base" self."multimethod-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multimethod-lib" = self.lib.mkRacketDerivation rec {
  pname = "multimethod-lib";
  src = self.lib.extractPath {
    path = "multimethod-lib";
    src = fetchgit {
    name = "multimethod-lib";
    url = "git://github.com/lexi-lambda/racket-multimethod.git";
    rev = "8a0903ebaedd919971c382eeb785f05080c7a8d6";
    sha256 = "0jbmvs6q14f58hfi9qvz8g4ndq13ybyy80y375w7455s7y3w3af0";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-spec" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multimethod-test" = self.lib.mkRacketDerivation rec {
  pname = "multimethod-test";
  src = self.lib.extractPath {
    path = "multimethod-test";
    src = fetchgit {
    name = "multimethod-test";
    url = "git://github.com/lexi-lambda/racket-multimethod.git";
    rev = "8a0903ebaedd919971c382eeb785f05080c7a8d6";
    sha256 = "0jbmvs6q14f58hfi9qvz8g4ndq13ybyy80y375w7455s7y3w3af0";
  };
  };
  racketThinBuildInputs = [ self."base" self."multimethod-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multipath-daemon" = self.lib.mkRacketDerivation rec {
  pname = "multipath-daemon";
  src = fetchgit {
    name = "multipath-daemon";
    url = "git://github.com/mordae/racket-multipath-daemon.git";
    rev = "4d8a2644d2641e9d263e83caef28b3bf6af63b88";
    sha256 = "0c8phvqx38201m7l8pza4g2rxlbpmign0pxmbcyx08x5wpfqqq83";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."unix-socket-lib" self."racket-doc" self."unstable-doc" self."unix-socket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "multiscope" = self.lib.mkRacketDerivation rec {
  pname = "multiscope";
  src = fetchgit {
    name = "multiscope";
    url = "git://github.com/michaelballantyne/multiscope.git";
    rev = "bc59bd53462a72ed3e67ec2555e94e871bc7e314";
    sha256 = "027d7wpiq68k9qfspnb5qzx9zg59nz8vqdcwzbfnv9x4fzjhl2q1";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mumble-ping" = self.lib.mkRacketDerivation rec {
  pname = "mumble-ping";
  src = fetchgit {
    name = "mumble-ping";
    url = "git://github.com/winny-/mumble-ping.git";
    rev = "3e450ef467c038b1a5100a53c96f65a0fe83e0c9";
    sha256 = "0i45pidcbw66lf4vj0hz0016n9vlmddp2v657qzc7psxskrxpypf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."rackunit-typed" self."bitsyntax" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "music" = self.lib.mkRacketDerivation rec {
  pname = "music";
  src = fetchgit {
    name = "music";
    url = "git://github.com/SuperDisk/lang-music.git";
    rev = "a5f9a6c456351d1b80950241cb1d82585043bc65";
    sha256 = "1lri1b378bvvdljggg2rbhdjdbda32ljb4b2zgb5vs9aap59whf9";
  };
  racketThinBuildInputs = [ self."base" self."binaryio-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mutable-match-lambda" = self.lib.mkRacketDerivation rec {
  pname = "mutable-match-lambda";
  src = fetchgit {
    name = "mutable-match-lambda";
    url = "git://github.com/AlexKnauth/mutable-match-lambda.git";
    rev = "371cb7e5407cc888ffd96ee5fff6facd9568a3fe";
    sha256 = "04gbp47dpcinb4j7fmbr1m4288bkdgpj9nad1rgv1gkzipsgs3vb";
  };
  racketThinBuildInputs = [ self."base" self."kw-utils" self."rackunit-lib" self."at-exp-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mutt" = self.lib.mkRacketDerivation rec {
  pname = "mutt";
  src = fetchgit {
    name = "mutt";
    url = "git://github.com/bennn/racket-mutt.git";
    rev = "6679f9f9478fda00b004f0d3a147bc29a77c772e";
    sha256 = "1m9cg5npngv8sh2yf17gq2z95ps3jc3s4blifkp5hmn0f66ydd6c";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."make-log-interceptor" self."scribble-lib" self."scribble-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."rackunit-abbrevs" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "my-cond" = self.lib.mkRacketDerivation rec {
  pname = "my-cond";
  src = fetchgit {
    name = "my-cond";
    url = "git://github.com/AlexKnauth/my-cond.git";
    rev = "1bb7066f69ba4619ac7d2ea0c292f80b78c5503b";
    sha256 = "05vjl0qwvnjna60crwfndnxz1sjgl9yj8vfqc51b8zbmj837i2zs";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."sweet-exp-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."sweet-exp" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mysterx" = self.lib.mkRacketDerivation rec {
  pname = "mysterx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/mysterx.zip";
    sha1 = "7d252b3645ef52f87d79a7e6a80f82a01bd91d55";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."racket-doc" self."at-exp-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzcom" = self.lib.mkRacketDerivation rec {
  pname = "mzcom";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/mzcom.zip";
    sha1 = "45ae7b8157a2b4eb03ed363ed39484be69e9ebe4";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scheme-lib" self."racket-doc" self."mysterx" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/mzscheme.zip";
    sha1 = "f13f33a68d53558278bcea1f5cbfd5c9248f1d0a";
  };
  racketThinBuildInputs = [ self."mzscheme-lib" self."mzscheme-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme-doc" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/mzscheme-doc.zip";
    sha1 = "5b9dd5e0f43754dfeae569524b3df737e14c095c";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."compatibility-lib" self."r5rs-lib" self."scheme-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme-lib" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/mzscheme-lib.zip";
    sha1 = "456e910221ccd67ff9a04ffdfa7506d7f9944584";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "namespaced-transformer" = self.lib.mkRacketDerivation rec {
  pname = "namespaced-transformer";
  src = self.lib.extractPath {
    path = "namespaced-transformer";
    src = fetchgit {
    name = "namespaced-transformer";
    url = "git://github.com/lexi-lambda/namespaced-transformer.git";
    rev = "4cdc1bdae09a07b78f23665267f2c7df4be5a7f6";
    sha256 = "0lfcxyb76iadqh7vhxqzg5fdgd3pyx6nsjqdibgam10dlppck45y";
  };
  };
  racketThinBuildInputs = [ self."namespaced-transformer-doc" self."namespaced-transformer-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "namespaced-transformer-doc" = self.lib.mkRacketDerivation rec {
  pname = "namespaced-transformer-doc";
  src = self.lib.extractPath {
    path = "namespaced-transformer-doc";
    src = fetchgit {
    name = "namespaced-transformer-doc";
    url = "git://github.com/lexi-lambda/namespaced-transformer.git";
    rev = "4cdc1bdae09a07b78f23665267f2c7df4be5a7f6";
    sha256 = "0lfcxyb76iadqh7vhxqzg5fdgd3pyx6nsjqdibgam10dlppck45y";
  };
  };
  racketThinBuildInputs = [ self."base" self."namespaced-transformer-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "namespaced-transformer-lib" = self.lib.mkRacketDerivation rec {
  pname = "namespaced-transformer-lib";
  src = self.lib.extractPath {
    path = "namespaced-transformer-lib";
    src = fetchgit {
    name = "namespaced-transformer-lib";
    url = "git://github.com/lexi-lambda/namespaced-transformer.git";
    rev = "4cdc1bdae09a07b78f23665267f2c7df4be5a7f6";
    sha256 = "0lfcxyb76iadqh7vhxqzg5fdgd3pyx6nsjqdibgam10dlppck45y";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nanopass" = self.lib.mkRacketDerivation rec {
  pname = "nanopass";
  src = fetchgit {
    name = "nanopass";
    url = "git://github.com/nanopass/nanopass-framework-racket.git";
    rev = "deac3a4bf937e1217ec54c5439710712b227fc5a";
    sha256 = "0zfyl2gnf9q92a5z92pjdbd95mfqi2abxfdsg346718rmg4fsmyr";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."compatibility-lib" self."unstable-pretty-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nat-traversal" = self.lib.mkRacketDerivation rec {
  pname = "nat-traversal";
  src = fetchgit {
    name = "nat-traversal";
    url = "git://github.com/tonyg/racket-nat-traversal.git";
    rev = "3983b52e1e23b820da1b90f514ddbe7d6398e0cb";
    sha256 = "1jm51mxd8isg18lb7nrlzrszws92i7khk4b9g41bskmn8ka86ly4";
  };
  racketThinBuildInputs = [ self."base" self."bitsyntax" self."web-server-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "natural-cli" = self.lib.mkRacketDerivation rec {
  pname = "natural-cli";
  src = fetchgit {
    name = "natural-cli";
    url = "git://github.com/zyrolasting/natural-cli.git";
    rev = "c7abc38d025159128d446ca1a6314ab909ffe920";
    sha256 = "0nsw2r56zwcrhpkaxy8bcpwmzb0xxwavynqvri9dp6km9r9clyvk";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."compatibility-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neologia" = self.lib.mkRacketDerivation rec {
  pname = "neologia";
  src = fetchgit {
    name = "neologia";
    url = "git://github.com/robertkleffner/neologia.git";
    rev = "92d6ccde9041dc07b5c0db1849b4e1c65cb3cf2d";
    sha256 = "15hw5xigknxg08pg0p9hwg7kmwm6j04dny0lfzipkh2gnwg69nzn";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."brag" self."beautiful-racket" self."beautiful-racket-lib" self."br-parser-tools-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nested-hash" = self.lib.mkRacketDerivation rec {
  pname = "nested-hash";
  src = fetchgit {
    name = "nested-hash";
    url = "git://github.com/BourgondAries/nested-hash.git";
    rev = "c562dbe1cf54d8604e56db14526f03c9b6c75b5b";
    sha256 = "1yph4fy05gxcqi1gkq3xphmk9vfkq2wgsbvj31b30fp2misswvw1";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net" = self.lib.mkRacketDerivation rec {
  pname = "net";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net.zip";
    sha1 = "91fbdedb6110552b85bb094e6fceb622514016b6";
  };
  racketThinBuildInputs = [ self."net-lib" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-cookies.zip";
    sha1 = "369527705b7285386436b6420c19195eb80be4ac";
  };
  racketThinBuildInputs = [ self."net-cookies-lib" self."net-cookies-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-doc" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-cookies-doc.zip";
    sha1 = "ec2c3fa81c1efa7685fe2ce29ec06da6aaf4b538";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."net-cookies-lib" self."web-server-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-lib" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-cookies-lib.zip";
    sha1 = "a4d0c53779b41fab616e40d8acb58b05eaea4407";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-test" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-cookies-test.zip";
    sha1 = "e43af717bf06cd46f7fa2b3a5ec437a3fd29baf0";
  };
  racketThinBuildInputs = [ self."base" self."net-cookies-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-doc" = self.lib.mkRacketDerivation rec {
  pname = "net-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-doc.zip";
    sha1 = "c3b35da19f0fbff288eeac9604478c849b3f47a3";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."compatibility-lib" self."net-lib" self."scribble-lib" self."web-server-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "net-ip" = self.lib.mkRacketDerivation rec {
  pname = "net-ip";
  src = self.lib.extractPath {
    path = "net-ip";
    src = fetchgit {
    name = "net-ip";
    url = "git://github.com/Bogdanp/racket-net-ip.git";
    rev = "6b75674d8074aee6a7f0c8dec22b8fe4314ee102";
    sha256 = "1rggbqldkf6sal48m5g7mm43v6kh4hh3gn3nw9859knhn7ha52sb";
  };
  };
  racketThinBuildInputs = [ self."net-ip-doc" self."net-ip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-ip-doc" = self.lib.mkRacketDerivation rec {
  pname = "net-ip-doc";
  src = self.lib.extractPath {
    path = "net-ip-doc";
    src = fetchgit {
    name = "net-ip-doc";
    url = "git://github.com/Bogdanp/racket-net-ip.git";
    rev = "6b75674d8074aee6a7f0c8dec22b8fe4314ee102";
    sha256 = "1rggbqldkf6sal48m5g7mm43v6kh4hh3gn3nw9859knhn7ha52sb";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-ip-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-ip-lib" = self.lib.mkRacketDerivation rec {
  pname = "net-ip-lib";
  src = self.lib.extractPath {
    path = "net-ip-lib";
    src = fetchgit {
    name = "net-ip-lib";
    url = "git://github.com/Bogdanp/racket-net-ip.git";
    rev = "6b75674d8074aee6a7f0c8dec22b8fe4314ee102";
    sha256 = "1rggbqldkf6sal48m5g7mm43v6kh4hh3gn3nw9859knhn7ha52sb";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-ip-test" = self.lib.mkRacketDerivation rec {
  pname = "net-ip-test";
  src = self.lib.extractPath {
    path = "net-ip-test";
    src = fetchgit {
    name = "net-ip-test";
    url = "git://github.com/Bogdanp/racket-net-ip.git";
    rev = "6b75674d8074aee6a7f0c8dec22b8fe4314ee102";
    sha256 = "1rggbqldkf6sal48m5g7mm43v6kh4hh3gn3nw9859knhn7ha52sb";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-ip-lib" self."quickcheck" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-jwt" = self.lib.mkRacketDerivation rec {
  pname = "net-jwt";
  src = fetchgit {
    name = "net-jwt";
    url = "git://github.com/RenaissanceBug/racket-jwt.git";
    rev = "9ba9f06101b71f2f148dc338e2d577389b588ec4";
    sha256 = "09ad6lw8cm9f2nzqzafckc151n6134cd8d4dlwj8wlsd47maa6kf";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."typed-racket-lib" self."typed-racket-more" self."sha" self."rackunit-lib" self."web-server-lib" self."racket-doc" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-racket-doc" self."option-bind" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-lib" = self.lib.mkRacketDerivation rec {
  pname = "net-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-lib.zip";
    sha1 = "8d6edf585d01452e995eea0ae57a7c4a26e1e01a";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-test" = self.lib.mkRacketDerivation rec {
  pname = "net-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/net-test.zip";
    sha1 = "e61cc1749447ab3b81c3e7296aaf49b99b1a61d9";
  };
  racketThinBuildInputs = [ self."net-test+racket-test" self."base" self."at-exp-lib" self."compatibility-lib" self."eli-tester" self."net-lib" self."rackunit-lib" self."sandbox-lib" self."web-server-lib" ];
  circularBuildInputs = [ "racket-test" "net-test" ];
  reverseCircularBuildInputs = [  ];
  };
  "net-test+racket-test" = self.lib.mkRacketDerivation rec {
  pname = "net-test+racket-test";

  extraSrcs = [ self."racket-test".src self."net-test".src ];
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."cext-lib" self."compatibility-lib" self."compiler-lib" self."data-lib" self."eli-tester" self."net-lib" self."option-contract-lib" self."pconvert-lib" self."planet-lib" self."racket-index" self."racket-test-core" self."rackunit-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."serialize-cstruct-lib" self."srfi-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "racket-test" "net-test" ];
  };
  "net2" = self.lib.mkRacketDerivation rec {
  pname = "net2";
  src = fetchgit {
    name = "net2";
    url = "git://github.com/jackfirth/racket-net2.git";
    rev = "b4247d52177120ff246b60c400b070dc962ee24b";
    sha256 = "15glddf0dh2kgp4fki4d80fw5v4a3fdivcjhik95xmrblmyg7myv";
  };
  racketThinBuildInputs = [ self."reprovide-lang" self."base" self."unix-socket-doc" self."unix-socket-lib" self."disposable" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "netrc" = self.lib.mkRacketDerivation rec {
  pname = "netrc";
  src = fetchgit {
    name = "netrc";
    url = "git://github.com/apg/netrc.git";
    rev = "af814d20a77910ab6de2161ac37d02586604a192";
    sha256 = "1fvxn76cly5p7n7bvnsw1g4264mfcs9bz1h6xqpv9as88pvyj9pk";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neu-cs2500-handin" = self.lib.mkRacketDerivation rec {
  pname = "neu-cs2500-handin";
  src = fetchgit {
    name = "neu-cs2500-handin";
    url = "git://github.com/nuprl/cs2500-client";
    rev = "d48c433d69d75ea03c029ec0207faa928796e757";
    sha256 = "1ccam253vr421cgy0531lvminr3b8lj66v1a7db4q5z32j8wa8di";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."net-lib" self."drracket" self."drracket-plugin-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neuron" = self.lib.mkRacketDerivation rec {
  pname = "neuron";
  src = self.lib.extractPath {
    path = "neuron";
    src = fetchgit {
    name = "neuron";
    url = "git://github.com/dedbox/racket-neuron.git";
    rev = "a8ecafec0c6398c35423348cb02ec229869c8b15";
    sha256 = "05gssp8k4rk32ncsj0xnhys8fylnhzsf078bv2gi7ayy7jzjn1p1";
  };
  };
  racketThinBuildInputs = [ self."neuron-lib" self."neuron-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neuron-doc" = self.lib.mkRacketDerivation rec {
  pname = "neuron-doc";
  src = self.lib.extractPath {
    path = "neuron-doc";
    src = fetchgit {
    name = "neuron-doc";
    url = "git://github.com/dedbox/racket-neuron.git";
    rev = "a8ecafec0c6398c35423348cb02ec229869c8b15";
    sha256 = "05gssp8k4rk32ncsj0xnhys8fylnhzsf078bv2gi7ayy7jzjn1p1";
  };
  };
  racketThinBuildInputs = [ self."base" self."neuron-lib" self."at-exp-lib" self."pict-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neuron-lib" = self.lib.mkRacketDerivation rec {
  pname = "neuron-lib";
  src = self.lib.extractPath {
    path = "neuron-lib";
    src = fetchgit {
    name = "neuron-lib";
    url = "git://github.com/dedbox/racket-neuron.git";
    rev = "a8ecafec0c6398c35423348cb02ec229869c8b15";
    sha256 = "05gssp8k4rk32ncsj0xnhys8fylnhzsf078bv2gi7ayy7jzjn1p1";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "neuron-shell" = self.lib.mkRacketDerivation rec {
  pname = "neuron-shell";
  src = fetchgit {
    name = "neuron-shell";
    url = "git://github.com/dedbox/racket-neuron-shell.git";
    rev = "6f60ede1866a8a419e44972ea11220d0457e8acb";
    sha256 = "07qyc9kz20jg2247vn0219fgsnnfcqg8k867llj69dkn7z2hsbad";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nevermore" = self.lib.mkRacketDerivation rec {
  pname = "nevermore";
  src = fetchgit {
    name = "nevermore";
    url = "git://github.com/Bogdanp/nevermore.git";
    rev = "20c6533176bd47c56aa94287fada6909b87ff03a";
    sha256 = "026qipz4ca0shwwgp6ngganw0l7lgi23baxh4935z181klx0hb9h";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nix" = self.lib.mkRacketDerivation rec {
  pname = "nix";
  src = fetchgit {
    name = "nix";
    url = "git://github.com/jubnzv/nix.rkt.git";
    rev = "a0e4107110c15880606b6098b97b73654e4cb50a";
    sha256 = "0ggxhrbhbgz850qqfvx5bq5abx9rs5nmr294yldy462marwl367s";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nlopt" = self.lib.mkRacketDerivation rec {
  pname = "nlopt";
  src = fetchgit {
    name = "nlopt";
    url = "git://github.com/jkominek/nlopt.git";
    rev = "52946146fe798bb35d1e601500d87e34f4c7365b";
    sha256 = "1mq4arkaj6zhk47qcrcfkrphh65y1bnlzz1dhmajnxyz33cfcbn4";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."math-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "no-vert-bar-lang" = self.lib.mkRacketDerivation rec {
  pname = "no-vert-bar-lang";
  src = fetchgit {
    name = "no-vert-bar-lang";
    url = "git://github.com/AlexKnauth/no-vert-bar-lang.git";
    rev = "3e31489f2b3aff73f50cade704b724b5578af7fb";
    sha256 = "0vsgn7qhx145fiq5c988q3vjvm3sgf1j3blcxkgp1wr5v7g13chi";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "non-det" = self.lib.mkRacketDerivation rec {
  pname = "non-det";
  src = fetchgit {
    name = "non-det";
    url = "git://github.com/jeapostrophe/non-det.git";
    rev = "e26cdb7cb8152df912e239323fad8bb6b3a8b05f";
    sha256 = "12gqids2g2cnn8vgzwkpzwmx1mzykp1i8lisq1abvqhaq1y0vrpl";
  };
  racketThinBuildInputs = [ self."chk-lib" self."base" self."text-table" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "north" = self.lib.mkRacketDerivation rec {
  pname = "north";
  src = self.lib.extractPath {
    path = "north";
    src = fetchgit {
    name = "north";
    url = "git://github.com/Bogdanp/racket-north.git";
    rev = "e51fa1dcc2e18175fc3ad59e9ee15e704ac98818";
    sha256 = "191z3xrz279j2ny0qq91k3r595aynkqdga0aw0n4473idvwzi3qk";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."gregor-lib" self."parser-tools-lib" self."at-exp-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "numformat-old" = self.lib.mkRacketDerivation rec {
  pname = "numformat-old";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/numformat-old.zip";
    sha1 = "e0b44f190a7a8c03169e4671a5d15cec5a619598";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "numspell" = self.lib.mkRacketDerivation rec {
  pname = "numspell";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/numspell.zip";
    sha1 = "60f30a535e6e11bb4c3596af14708fb6cd9402ea";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nvim-client" = self.lib.mkRacketDerivation rec {
  pname = "nvim-client";
  src = self.lib.extractPath {
    path = "nvim-client";
    src = fetchgit {
    name = "nvim-client";
    url = "https://gitlab.com/HiPhish/neovim.rkt.git";
    rev = "c7d0a3d7ceaebd59955e6d2aee16352098c82d8a";
    sha256 = "0hczdaah91bm19d1ilnrpzpf3ds4wmnl6n2dxjpmgas43hpiyqa4";
  };
  };
  racketThinBuildInputs = [ self."base" self."msgpack" self."unix-socket-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."unix-socket-doc" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "object-backtrace" = self.lib.mkRacketDerivation rec {
  pname = "object-backtrace";
  src = fetchgit {
    name = "object-backtrace";
    url = "git://github.com/samth/object-backtrace.git";
    rev = "40de72e273b3c8684ebd2be20989203049e2434a";
    sha256 = "06ddzphww0n1fws8rxr2likgn4riyvwa0h6b0nyjxs6dri380mbc";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ocelot" = self.lib.mkRacketDerivation rec {
  pname = "ocelot";
  src = fetchgit {
    name = "ocelot";
    url = "git://github.com/jamesbornholt/ocelot.git";
    rev = "58b687cdf22f6c1db4b3322fdbc5b82e9d1bce2b";
    sha256 = "115c4xppapwv7yldhacingrx2klks3vbqrjrsdyrpfqqgvr3g7pf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."sandbox-lib" self."rosette" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "oii-422-handin-client" = self.lib.mkRacketDerivation rec {
  pname = "oii-422-handin-client";
  src = fetchgit {
    name = "oii-422-handin-client";
    url = "git://github.com/ifigueroap/oii-422-handin-client.git";
    rev = "29d62748d335a1ab283efc3e28c5c93c3737501a";
    sha256 = "01pk0pkyld49ri9y1c7k7mvs0j3lifplzjrycx96pizgixb2pqam";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."net-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "onlog" = self.lib.mkRacketDerivation rec {
  pname = "onlog";
  src = fetchgit {
    name = "onlog";
    url = "git://github.com/fmind/onlog.git";
    rev = "d6756ca99c8f647f47126716fb24698a7f77c80f";
    sha256 = "1zv3mycncr32z5z4k7n9kl2ldy39wsg4dq78g16w3g0mzngxd2bz";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "open-app" = self.lib.mkRacketDerivation rec {
  pname = "open-app";
  src = fetchgit {
    name = "open-app";
    url = "git://github.com/SimonLSchlee/open-app.git";
    rev = "5503f0d2b5e398c864e6bdacfac9c672bf9b9869";
    sha256 = "0i3cicyl6x9sx8ly93fv4q34i979kg9plpzg1bjh0vd9c7r7d6bf";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "openal" = self.lib.mkRacketDerivation rec {
  pname = "openal";
  src = fetchgit {
    name = "openal";
    url = "git://github.com/jeapostrophe/openal.git";
    rev = "50b52525426f4bf2e0c3fd4c2ab4d0c59598e99a";
    sha256 = "1gl4sag5v5zp44i4rjp5wp4knqnf1icnxw8sxl7x3a2rr6f28srs";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "opencl" = self.lib.mkRacketDerivation rec {
  pname = "opencl";
  src = fetchgit {
    name = "opencl";
    url = "git://github.com/jeapostrophe/opencl.git";
    rev = "f984050b0c02beb6df186d1d531c4a92a98df1a1";
    sha256 = "1q4agl1125ksyps616q58lglzymp7dp7qw63jbvfja2zcn947yb1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."superc" self."at-exp-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "opencpu" = self.lib.mkRacketDerivation rec {
  pname = "opencpu";
  src = fetchgit {
    name = "opencpu";
    url = "git://github.com/LiberalArtist/opencpu.git";
    rev = "ab5433418a3a19aeafe239901c3a530d745e2dbd";
    sha256 = "092f1dic9w4bkwajzh90ds21srwshgi9cq2qx946c6j56gcfbahb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."adjutor" self."scribble-lib" self."racket-doc" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "opencv" = self.lib.mkRacketDerivation rec {
  pname = "opencv";
  src = fetchgit {
    name = "opencv";
    url = "git://github.com/oetr/racket-opencv.git";
    rev = "8124eb6b620769137656547e83f9d9587ab37c23";
    sha256 = "0qis0gbcchhxi7f3v4ijrdyh3wbdnf10v0vvam2pqx6m53i59hfr";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "opengl" = self.lib.mkRacketDerivation rec {
  pname = "opengl";
  src = fetchgit {
    name = "opengl";
    url = "git://github.com/stephanh42/RacketGL.git";
    rev = "1aaf2b2836680f807fbec5234ed475585b41b4ab";
    sha256 = "1dc55jhwydin6f1c2bpzls3fzip3gg2j5aq2gwrkzvifj6p8wxj6";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."scribble-lib" self."srfi-lite-lib" self."draw-doc" self."gui-doc" self."gui-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "openh264-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "openh264-x86_64-macosx";
  src = self.lib.extractPath {
    path = "openh264-x86_64-macosx";
    src = fetchgit {
    name = "openh264-x86_64-macosx";
    url = "git://github.com/videolang/native-pkgs.git";
    rev = "61c4b07ffd82127a049cf12f74c09c20730eba1d";
    sha256 = "0mqw649562qx823iw76q5v8m40z2n5psbhva6r7n53497a83hmpn";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "openmpi" = self.lib.mkRacketDerivation rec {
  pname = "openmpi";
  src = fetchgit {
    name = "openmpi";
    url = "git://github.com/jeapostrophe/openmpi.git";
    rev = "5aea47a93cf08efdd1bf2cb470c059b5197d04c1";
    sha256 = "0h61kv9bpzbyb2i7hhwg6wy3vdjhr1inj7a8y36wc29gxzm7krvm";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."scribble-lib" self."at-exp-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "openweather" = self.lib.mkRacketDerivation rec {
  pname = "openweather";
  src = fetchgit {
    name = "openweather";
    url = "https://gitlab.com/RayRacine/openweather.git";
    rev = "a0c4e4832b3ac05c1c38fbf64c6ce3ff583882e7";
    sha256 = "0vmfkis5r96iq5d12b9p79pa67d5j3mi5fqzh67001z5iicgisf3";
  };
  racketThinBuildInputs = [ self."opt" self."uri" self."http11" self."tjson" self."typed-racket-lib" self."base" self."scribble-lib" self."racket-doc" self."typed-racket-lib" self."typed-racket-more" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "operational-transformation" = self.lib.mkRacketDerivation rec {
  pname = "operational-transformation";
  src = self.lib.extractPath {
    path = "operational-transformation";
    src = fetchgit {
    name = "operational-transformation";
    url = "git://github.com/tonyg/racket-operational-transformation.git";
    rev = "1960b7f70138a9de6e3ceb2943b8ca46c83d94ae";
    sha256 = "0z6np1k73kacb5731xa1bsbgsjch4cwzbilrjnfs6llhsh2yhrnc";
  };
  };
  racketThinBuildInputs = [ self."base" self."operational-transformation-demo" self."operational-transformation-lib" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "operational-transformation-demo" = self.lib.mkRacketDerivation rec {
  pname = "operational-transformation-demo";
  src = self.lib.extractPath {
    path = "operational-transformation-demo";
    src = fetchgit {
    name = "operational-transformation-demo";
    url = "git://github.com/tonyg/racket-operational-transformation.git";
    rev = "1960b7f70138a9de6e3ceb2943b8ca46c83d94ae";
    sha256 = "0z6np1k73kacb5731xa1bsbgsjch4cwzbilrjnfs6llhsh2yhrnc";
  };
  };
  racketThinBuildInputs = [ self."base" self."operational-transformation-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "operational-transformation-lib" = self.lib.mkRacketDerivation rec {
  pname = "operational-transformation-lib";
  src = self.lib.extractPath {
    path = "operational-transformation-lib";
    src = fetchgit {
    name = "operational-transformation-lib";
    url = "git://github.com/tonyg/racket-operational-transformation.git";
    rev = "1960b7f70138a9de6e3ceb2943b8ca46c83d94ae";
    sha256 = "0z6np1k73kacb5731xa1bsbgsjch4cwzbilrjnfs6llhsh2yhrnc";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "opt" = self.lib.mkRacketDerivation rec {
  pname = "opt";
  src = fetchgit {
    name = "opt";
    url = "https://gitlab.com/RayRacine/opt.git";
    rev = "83544737512709bfbdf5d65a956ee12c4cc7e822";
    sha256 = "0ybbpq5a42lp12sgl5c78i5bav24v43sl8yjbax9f8d6i158vb4q";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."base" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "optimization-coach" = self.lib.mkRacketDerivation rec {
  pname = "optimization-coach";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/optimization-coach.zip";
    sha1 = "1be0955c09bd502236afc5090dc7fb0ed63e8b1d";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."typed-racket-lib" self."profile-lib" self."rackunit-lib" self."gui-lib" self."data-lib" self."source-syntax" self."images-lib" self."sandbox-lib" self."string-constants-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-bind" = self.lib.mkRacketDerivation rec {
  pname = "option-bind";
  src = fetchgit {
    name = "option-bind";
    url = "git://github.com/RenaissanceBug/option-bind.git";
    rev = "8d8346d612e401d7b44a04a121881f66e5a43cf6";
    sha256 = "03p2s29r798pm72mfmnskq5s28zy8hm9szj7v024qdi37xv93way";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract" = self.lib.mkRacketDerivation rec {
  pname = "option-contract";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/option-contract.zip";
    sha1 = "678391bfbee61f0a9aeaa00503486546361efc37";
  };
  racketThinBuildInputs = [ self."option-contract-lib" self."option-contract-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-doc" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/option-contract-doc.zip";
    sha1 = "b3da3c9c05a86911fbdb7aa19d436765e0456717";
  };
  racketThinBuildInputs = [ self."base" self."option-contract-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-lib" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/option-contract-lib.zip";
    sha1 = "e5619783253a030cdbf25cf5774b0a6f06142a2e";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-test" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/option-contract-test.zip";
    sha1 = "2f40cc9b218d154a98e2dfedb152d088a77b15d9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."option-contract-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "org-mode" = self.lib.mkRacketDerivation rec {
  pname = "org-mode";
  src = fetchgit {
    name = "org-mode";
    url = "git://github.com/jeapostrophe/org-mode.git";
    rev = "49b1f46aaccc02fa1cedde36b8eda3ffa6a772ec";
    sha256 = "10al372q0xbkxpl1955l4s58spsx382d7jq36xrcq4d9n3dzi50g";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "osc" = self.lib.mkRacketDerivation rec {
  pname = "osc";
  src = fetchgit {
    name = "osc";
    url = "git://github.com/jbclements/osc.git";
    rev = "18caebb14eefe3482976e738654aee2f18c5f88d";
    sha256 = "0y195jbxivj93zv469ll8w7n0x6259fm70rj5d2pzk5gfdns8ivl";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "overeasy" = self.lib.mkRacketDerivation rec {
  pname = "overeasy";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/overeasy.zip";
    sha1 = "01df274d364d0fd0925c50d87c4caeab19c37c6e";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."mcfly" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "overscan" = self.lib.mkRacketDerivation rec {
  pname = "overscan";
  src = fetchgit {
    name = "overscan";
    url = "git://github.com/mwunsch/overscan.git";
    rev = "f198e6b4c1f64cf5720e66ab5ad27fdc4b9e67e9";
    sha256 = "1dpliav9wa1aaniqm5ynwy7c0wsrq4v582wvkl3fpzvgd5ldpclz";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."draw-lib" self."gui-lib" self."sgl" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "package-analysis" = self.lib.mkRacketDerivation rec {
  pname = "package-analysis";
  src = fetchgit {
    name = "package-analysis";
    url = "git://github.com/jackfirth/package-analysis.git";
    rev = "188a5328b78be35a50e28196f5e5f045ad289fb3";
    sha256 = "1kq9lxa76vrgyaqjdbzhy9svwzkn7kvl4dv3fkj1j6wrn4zgy5ck";
  };
  racketThinBuildInputs = [ self."base" self."rebellion" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "packet-socket" = self.lib.mkRacketDerivation rec {
  pname = "packet-socket";
  src = fetchgit {
    name = "packet-socket";
    url = "git://github.com/tonyg/racket-packet-socket.git";
    rev = "831e638e9aa9b0c3c8ecc2cbb4d1b91f57b93f1b";
    sha256 = "13vhdlvdhcm0m7i8dq66m9zr4v33j8k9jiqbcqc92ps5pzp21cs8";
  };
  racketThinBuildInputs = [ self."base" self."dynext-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "paddle" = self.lib.mkRacketDerivation rec {
  pname = "paddle";
  src = fetchgit {
    name = "paddle";
    url = "git://github.com/jadudm/paddle.git";
    rev = "38e2ff034635b988549d875bb9d8bd1ab0252ad2";
    sha256 = "1w3q6pjv0g1h1cdk70zanfqmfbm2a0gfmnijhlfz6qrr21k5jpln";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."sgl" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pangu" = self.lib.mkRacketDerivation rec {
  pname = "pangu";
  src = fetchgit {
    name = "pangu";
    url = "git://github.com/kisaragi-hiu/pangu.rkt.git";
    rev = "56c2d70132e0d756dc69f9777eb752ff989f5ede";
    sha256 = "0rgvbyn9pcx00s7slhjl8lvg4ps3ji87ljw9vvsqz0xdbgfq9cry";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parameter" = self.lib.mkRacketDerivation rec {
  pname = "parameter";
  src = fetchgit {
    name = "parameter";
    url = "git://github.com/samth/parameter.plt.git";
    rev = "d084723e260a133e792317286fb05494aabc29ed";
    sha256 = "15i75ccjrq544qkwlwfyx4j4kfyxainfdvm3za62dq0sbmsm2g2n";
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "paren-shape" = self.lib.mkRacketDerivation rec {
  pname = "paren-shape";
  src = fetchgit {
    name = "paren-shape";
    url = "git://github.com/AlexKnauth/paren-shape.git";
    rev = "0ad6a34d3e93088e3e6c5a69b78a0724d5f4290f";
    sha256 = "059zasy5wc3ipn5krcn2masv9xvbfxva98570d7kicx0an1n46cw";
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."syntax-classes-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parendown" = self.lib.mkRacketDerivation rec {
  pname = "parendown";
  src = self.lib.extractPath {
    path = "parendown";
    src = fetchgit {
    name = "parendown";
    url = "git://github.com/lathe/parendown-for-racket.git";
    rev = "f89879042a7a868bc0a83acd8bdaf4eb9427ff76";
    sha256 = "1gqld322bnmyvzxm3sbkrzqv0ycykznw8hkz7cfcbwraw9zb1i9c";
  };
  };
  racketThinBuildInputs = [ self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parendown-doc" = self.lib.mkRacketDerivation rec {
  pname = "parendown-doc";
  src = self.lib.extractPath {
    path = "parendown-doc";
    src = fetchgit {
    name = "parendown-doc";
    url = "git://github.com/lathe/parendown-for-racket.git";
    rev = "f89879042a7a868bc0a83acd8bdaf4eb9427ff76";
    sha256 = "1gqld322bnmyvzxm3sbkrzqv0ycykznw8hkz7cfcbwraw9zb1i9c";
  };
  };
  racketThinBuildInputs = [ self."base" self."parendown-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parendown-lib" = self.lib.mkRacketDerivation rec {
  pname = "parendown-lib";
  src = self.lib.extractPath {
    path = "parendown-lib";
    src = fetchgit {
    name = "parendown-lib";
    url = "git://github.com/lathe/parendown-for-racket.git";
    rev = "f89879042a7a868bc0a83acd8bdaf4eb9427ff76";
    sha256 = "1gqld322bnmyvzxm3sbkrzqv0ycykznw8hkz7cfcbwraw9zb1i9c";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parendown-test" = self.lib.mkRacketDerivation rec {
  pname = "parendown-test";
  src = self.lib.extractPath {
    path = "parendown-test";
    src = fetchgit {
    name = "parendown-test";
    url = "git://github.com/lathe/parendown-for-racket.git";
    rev = "f89879042a7a868bc0a83acd8bdaf4eb9427ff76";
    sha256 = "1gqld322bnmyvzxm3sbkrzqv0ycykznw8hkz7cfcbwraw9zb1i9c";
  };
  };
  racketThinBuildInputs = [ self."base" self."parendown-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parenlog" = self.lib.mkRacketDerivation rec {
  pname = "parenlog";
  src = fetchgit {
    name = "parenlog";
    url = "git://github.com/jeapostrophe/parenlog.git";
    rev = "b02b9960c18b3c238b08a68d334f7ac2641e785c";
    sha256 = "1514rvhdc2j1hmkb6701ps36f6538am0a90k8l40k3nlm44dm5p8";
  };
  racketThinBuildInputs = [ self."base" self."chk-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parquet" = self.lib.mkRacketDerivation rec {
  pname = "parquet";
  src = fetchgit {
    name = "parquet";
    url = "git://github.com/johnstonskj/racket-parquet.git";
    rev = "19a26155d832d1102003ddd67dcd40c2fb1c5325";
    sha256 = "1www83niqy5fpzywmsrd3kv1dlrbw7k3bkafg5s1xy39ll9aw9m2";
  };
  racketThinBuildInputs = [ self."base" self."thrift" self."rackunit-lib" self."racket-index" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parsack" = self.lib.mkRacketDerivation rec {
  pname = "parsack";
  src = fetchgit {
    name = "parsack";
    url = "git://github.com/stchang/parsack.git";
    rev = "3a02d3788b7bb5d6b4a05b3b2651d9309005c0fd";
    sha256 = "1yx4b839sbcwrs915v123xqs4qf7l8frkqd6bbbwyqk314g31myg";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parse-qif" = self.lib.mkRacketDerivation rec {
  pname = "parse-qif";
  src = fetchgit {
    name = "parse-qif";
    url = "git://github.com/jbclements/parse-qif.git";
    rev = "e2adbda585b9602865cc8932f2aa1006291fd74a";
    sha256 = "0lp2h8wla4sd1pf39gzc7jbdglk2gd11mfzp4b3flc9xh5sqlymg";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-combinator" = self.lib.mkRacketDerivation rec {
  pname = "parser-combinator";
  src = fetchgit {
    name = "parser-combinator";
    url = "git://github.com/nixpulvis/parser-combinator.git";
    rev = "9635c0479c1841e122a75faa35d1d76333ef3cb6";
    sha256 = "18vqvdbjs8a808crk21ynh3p7ghah71zwdilmgwn231h02cd9555";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."htdp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-tools" = self.lib.mkRacketDerivation rec {
  pname = "parser-tools";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/parser-tools.zip";
    sha1 = "4213cc4c807e742ed0ab4846cf6ddb501f316650";
  };
  racketThinBuildInputs = [ self."parser-tools-lib" self."parser-tools-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-tools-doc" = self.lib.mkRacketDerivation rec {
  pname = "parser-tools-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/parser-tools-doc.zip";
    sha1 = "4de3c01da66ae74458780e386ad6adcdbc190dc4";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."parser-tools-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-tools-lib" = self.lib.mkRacketDerivation rec {
  pname = "parser-tools-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/parser-tools-lib.zip";
    sha1 = "a06b4d42a954b828ceb82947d18478a74760cd35";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parted" = self.lib.mkRacketDerivation rec {
  pname = "parted";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/parted.zip";
    sha1 = "32e6a6df9f53a568022c1fb7e50d96fc8025fdef";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."mcfly" self."overeasy" self."sudo" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pcf" = self.lib.mkRacketDerivation rec {
  pname = "pcf";
  src = fetchgit {
    name = "pcf";
    url = "git://github.com/dvanhorn/pcf.git";
    rev = "f04e2ff7f34b89a3dc6c2a70a6a3283f954d3a67";
    sha256 = "0f279rbzrcy0hxrx5cmyyhfbsmh38ym06d289sjjqh3bdk6wlzkh";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."redex-pict-lib" self."unstable-lib" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."redex-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pcg" = self.lib.mkRacketDerivation rec {
  pname = "pcg";
  src = fetchgit {
    name = "pcg";
    url = "git://github.com/BourgondAries/pcg.git";
    rev = "4a03a774377ff84aae29c563bc5170edd9a200e0";
    sha256 = "0hi5dfkgi19b9wq8qa1gxxfdnq8q0ch4wj0yxli6ai8j8nnr9kmg";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pconvert-lib" = self.lib.mkRacketDerivation rec {
  pname = "pconvert-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pconvert-lib.zip";
    sha1 = "ac0e2a29a9f1f89a0ef408852dd71f6aee8eb0cd";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pconvert-test" = self.lib.mkRacketDerivation rec {
  pname = "pconvert-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pconvert-test.zip";
    sha1 = "3a578fa420744922bab48fdbfbcb32951ebcb2e9";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pdf-read" = self.lib.mkRacketDerivation rec {
  pname = "pdf-read";
  src = fetchgit {
    name = "pdf-read";
    url = "git://github.com/gcr/pdf-read.git";
    rev = "bc442055764128efb06badeac8b4bfd026475106";
    sha256 = "0qcsilzvcgc9x6fc3r23m26vlw0yfz9cn1g1vcbh13d4kqxxanyd";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."draw-lib" self."slideshow-lib" self."scribble-lib" self."racket-doc" self."pict-doc" self."draw-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "peg" = self.lib.mkRacketDerivation rec {
  pname = "peg";
  src = fetchgit {
    name = "peg";
    url = "git://github.com/rain-1/racket-peg.git";
    rev = "5191749fa13686045f2170358097eb81d710a9de";
    sha256 = "0ylha9afhrv53qswxsiw43pdh8v5bwajr1i49nfjzx29m2gkzjwr";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "peony" = self.lib.mkRacketDerivation rec {
  pname = "peony";
  src = fetchgit {
    name = "peony";
    url = "git://github.com/silver-ag/peony.git";
    rev = "9d07d8fbe3219fb340b0df9c7a5ef0e51fe1d874";
    sha256 = "0hjlcvb7sfgaa79z4x30yjilsfnnj827v578qhc7wy1zgb59z8wg";
  };
  racketThinBuildInputs = [ self."base" self."web-server" self."db-doc" self."db-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "persistent-array" = self.lib.mkRacketDerivation rec {
  pname = "persistent-array";
  src = fetchgit {
    name = "persistent-array";
    url = "git://github.com/samth/persistent-array.git";
    rev = "9299dd5b6b33a953bdc4bfca3edcb956a86a35e2";
    sha256 = "0816mgqnd10pbyi7s6a2wb83nb22ywpvg03vaff6qd6h9sd219l8";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "persistent-union-find" = self.lib.mkRacketDerivation rec {
  pname = "persistent-union-find";
  src = fetchgit {
    name = "persistent-union-find";
    url = "git://github.com/samth/persistent-union-find.git";
    rev = "f95278e362550a59dae327bd15f9f609009de6d0";
    sha256 = "1dv855lmdimasaanbd2i2py1mv957s6brjgf6ac840zy0xhv7j73";
  };
  racketThinBuildInputs = [ self."base" self."persistent-array" self."r6rs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pex" = self.lib.mkRacketDerivation rec {
  pname = "pex";
  src = fetchgit {
    name = "pex";
    url = "git://github.com/mordae/racket-pex.git";
    rev = "57997dcdcf5533249d65a9040d55763b22dda57a";
    sha256 = "13k31cm89xp3nxiv022q0briaj0ndwc6qxlnwij7vhbv13riy1yd";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."mordae" self."libserialport" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pfds" = self.lib.mkRacketDerivation rec {
  pname = "pfds";
  src = fetchgit {
    name = "pfds";
    url = "git://github.com/takikawa/tr-pfds.git";
    rev = "a08810bdfc760bb9ed68d08ea222a59135d9a203";
    sha256 = "19cx5iv335xs82bw8xkql801pk0af5nmlmyxvwfd4j3fg7xlj5ym";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-compatibility" self."scheme-lib" self."at-exp-lib" self."htdp-lib" self."racket-doc" self."scribble-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "phc-adt" = self.lib.mkRacketDerivation rec {
  pname = "phc-adt";
  src = self.lib.extractPath {
    path = "phc-adt";
    src = fetchgit {
    name = "phc-adt";
    url = "git://github.com/jsmaniac/phc-adt.git";
    rev = "b9b031a9d28c1dbb96a36856244fa2333241e1e4";
    sha256 = "1299r7sv1cjdm30d07qcj1npr1p15jvvdfvynxi9bfzgh78mcgan";
  };
  };
  racketThinBuildInputs = [ self."phc-adt-lib" self."phc-adt-doc" self."phc-adt-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "phc-adt-doc" = self.lib.mkRacketDerivation rec {
  pname = "phc-adt-doc";
  src = self.lib.extractPath {
    path = "phc-adt-doc";
    src = fetchgit {
    name = "phc-adt-doc";
    url = "git://github.com/jsmaniac/phc-adt.git";
    rev = "b9b031a9d28c1dbb96a36856244fa2333241e1e4";
    sha256 = "1299r7sv1cjdm30d07qcj1npr1p15jvvdfvynxi9bfzgh78mcgan";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."hyper-literate" self."phc-adt-lib" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" self."scribble-enhanced" self."scribble-math" self."type-expander" self."xlist" self."alexis-util" self."extensible-parser-specifications" self."multi-id" self."phc-toolkit" self."remember" self."threading" self."trivial" self."typed-struct-props" self."datatype" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "phc-adt-lib" = self.lib.mkRacketDerivation rec {
  pname = "phc-adt-lib";
  src = self.lib.extractPath {
    path = "phc-adt-lib";
    src = fetchgit {
    name = "phc-adt-lib";
    url = "git://github.com/jsmaniac/phc-adt.git";
    rev = "b9b031a9d28c1dbb96a36856244fa2333241e1e4";
    sha256 = "1299r7sv1cjdm30d07qcj1npr1p15jvvdfvynxi9bfzgh78mcgan";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."hyper-literate" self."multi-id" self."phc-toolkit" self."remember" self."type-expander" self."extensible-parser-specifications" self."alexis-util" self."typed-struct-props" self."match-string" self."xlist" self."compatibility-lib" self."generic-bind" self."datatype" self."at-exp-lib" self."sandbox-lib" self."scribble-enhanced" self."scribble-lib" self."scribble-math" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "phc-adt-test" = self.lib.mkRacketDerivation rec {
  pname = "phc-adt-test";
  src = self.lib.extractPath {
    path = "phc-adt-test";
    src = fetchgit {
    name = "phc-adt-test";
    url = "git://github.com/jsmaniac/phc-adt.git";
    rev = "b9b031a9d28c1dbb96a36856244fa2333241e1e4";
    sha256 = "1299r7sv1cjdm30d07qcj1npr1p15jvvdfvynxi9bfzgh78mcgan";
  };
  };
  racketThinBuildInputs = [ self."base" self."phc-adt-lib" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."multi-id" self."phc-toolkit" self."type-expander" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "phc-toolkit" = self.lib.mkRacketDerivation rec {
  pname = "phc-toolkit";
  src = fetchgit {
    name = "phc-toolkit";
    url = "git://github.com/jsmaniac/phc-toolkit.git";
    rev = "396409cb63216e9b94d7eed4ebc43292c94b195d";
    sha256 = "1i0wd1l2vi5982fk7qar2mbqgg9lsaawl6bcf9iylgqnw853ldm2";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."alexis-util" self."typed-racket-lib" self."typed-racket-more" self."reprovide-lang" self."type-expander" self."hyper-literate" self."version-case" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."predicates" self."rackunit-doc" self."scribble-math" self."drracket" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "php-parser" = self.lib.mkRacketDerivation rec {
  pname = "php-parser";
  src = fetchgit {
    name = "php-parser";
    url = "git://github.com/antoineb/php-parser.git";
    rev = "159665a9078e46f1ea7712363f83cb8e5d9a2703";
    sha256 = "18d5g095fb7d2kz0bq8wrfhadxlwhgl0nxp8v58l7z1vc1pr0zj3";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict" = self.lib.mkRacketDerivation rec {
  pname = "pict";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict.zip";
    sha1 = "f71ecabbc29f5654fe3262ba901def1f73fd5d54";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-abbrevs" = self.lib.mkRacketDerivation rec {
  pname = "pict-abbrevs";
  src = fetchgit {
    name = "pict-abbrevs";
    url = "https://gitlab.com/bengreenman/pict-abbrevs.git";
    rev = "a9b4b9b88e6483b7e8f8f00dade9094907861a70";
    sha256 = "0vvdnrljjfjc73nkdzpn3lxv3r8vy6k8mc0cv575n720wc73dg5w";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."lang-file" self."draw-lib" self."slideshow-lib" self."ppict" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."gui-doc" self."pict-doc" self."draw-doc" self."plot-doc" self."plot-lib" self."scribble-lib" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-doc" = self.lib.mkRacketDerivation rec {
  pname = "pict-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-doc.zip";
    sha1 = "e5c1cfc964b6f2160ee943c0f75b2695e04b738a";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."draw-lib" self."gui-lib" self."scribble-lib" self."slideshow-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-lib" = self.lib.mkRacketDerivation rec {
  pname = "pict-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-lib.zip";
    sha1 = "f0d8e378dc5fcdb5515da20674f1502856f247b4";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."draw-lib" self."syntax-color-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-snip.zip";
    sha1 = "ff9c15eeb5c702c356068855b6a93b7d43243a53";
  };
  racketThinBuildInputs = [ self."pict-snip-lib" self."pict-snip-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-doc" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-snip-doc.zip";
    sha1 = "9d142c2c9ae5f2a31a66b3f662858bc915fdaaa9";
  };
  racketThinBuildInputs = [ self."base" self."pict-snip-lib" self."gui-doc" self."pict-doc" self."pict-lib" self."racket-doc" self."scribble-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-lib" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-snip-lib.zip";
    sha1 = "f1db2ceed935b827a9219be2081e397fa888a206";
  };
  racketThinBuildInputs = [ self."draw-lib" self."snip-lib" self."pict-lib" self."wxme-lib" self."base" self."rackunit-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-test" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-snip-test.zip";
    sha1 = "84bbe943ba3ec0f9b3146b38a43cc2049e1c3ae2";
  };
  racketThinBuildInputs = [ self."base" self."pict-snip-lib" self."draw-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-test" = self.lib.mkRacketDerivation rec {
  pname = "pict-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/pict-test.zip";
    sha1 = "6c483513e2f0a75d8aa2fa77c216d4c735492296";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."rackunit-lib" self."htdp-lib" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict3d" = self.lib.mkRacketDerivation rec {
  pname = "pict3d";
  src = fetchgit {
    name = "pict3d";
    url = "git://github.com/jeapostrophe/pict3d.git";
    rev = "b73e77c66461081934eaeeb17f079841a0118387";
    sha256 = "13x6agc9yjbqdg5bw3vld8ivfgpab5cpf4zy9sqvjsvld4qq851r";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."srfi-lite-lib" self."typed-racket-lib" self."typed-racket-more" self."math-lib" self."scribble-lib" self."gui-lib" self."pconvert-lib" self."pict-lib" self."profile-lib" self."pfds" self."unstable-lib" self."draw-doc" self."gui-doc" self."gui-lib" self."racket-doc" self."plot-doc" self."plot-lib" self."plot-gui-lib" self."images-doc" self."images-lib" self."htdp-doc" self."htdp-lib" self."pict-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict3d-die-cut" = self.lib.mkRacketDerivation rec {
  pname = "pict3d-die-cut";
  src = fetchgit {
    name = "pict3d-die-cut";
    url = "git://github.com/mflatt/pict3d-die-cut.git";
    rev = "29354f8dd2e9f964da834903332318a995d15727";
    sha256 = "1hw51frdpq8yfh87yp3w80gg5ilx0vbyr8zngdw4v7giw8mp821b";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict3d" self."glu-tessellate" self."draw-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict3d-orig" = self.lib.mkRacketDerivation rec {
  pname = "pict3d-orig";
  src = fetchgit {
    name = "pict3d-orig";
    url = "git://github.com/ntoronto/pict3d.git";
    rev = "09283c9d930c63b6a6a3f2caa43e029222091bdb";
    sha256 = "0b5xdq9rlxbbzp1kf5vmv6s84sh2gjg2lb3gbvif04ivi25b8s3i";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."srfi-lite-lib" self."typed-racket-lib" self."typed-racket-more" self."math-lib" self."scribble-lib" self."gui-lib" self."pconvert-lib" self."pict-lib" self."profile-lib" self."pfds" self."draw-doc" self."gui-doc" self."gui-lib" self."racket-doc" self."plot-doc" self."plot-lib" self."plot-gui-lib" self."images-doc" self."images-lib" self."htdp-doc" self."htdp-lib" self."pict-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "picturing-programs" = self.lib.mkRacketDerivation rec {
  pname = "picturing-programs";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/picturing-programs.zip";
    sha1 = "33226d5f8deb25767cedb51c2db6e137aea1245b";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."snip-lib" self."htdp-lib" self."racket-doc" self."htdp-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "picturing-programs-typed" = self.lib.mkRacketDerivation rec {
  pname = "picturing-programs-typed";
  src = fetchgit {
    name = "picturing-programs-typed";
    url = "git://github.com/maueroats/picturing-programs-typed.git";
    rev = "82dd9c1938c0fa9fdb5ea95849f7ca6f3a082edd";
    sha256 = "14w8svsf8jbv7nvv384jwv35yv2wkidl973qp5l1imlnwa4k9qh0";
  };
  racketThinBuildInputs = [ self."base" self."2htdp-typed" self."picturing-programs" self."draw-lib" self."htdp-lib" self."typed-racket-lib" self."typed-racket-more" self."unstable-list-lib" self."unstable-contract-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pidec" = self.lib.mkRacketDerivation rec {
  pname = "pidec";
  src = fetchgit {
    name = "pidec";
    url = "git://github.com/logc/pidec.git";
    rev = "4ec0b094709d83d54cb1de69209ecfd6a642573d";
    sha256 = "0sh2mi3c2ds7drdapvznpgnaazb0fikgm46x6q16nqw3wziw2cmc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."math-lib" self."typed-racket-lib" self."while-loop" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pie" = self.lib.mkRacketDerivation rec {
  pname = "pie";
  src = fetchgit {
    name = "pie";
    url = "git://github.com/the-little-typer/pie.git";
    rev = "a698d4cacd6823b5161221596d34bd17ce5282b8";
    sha256 = "14lf64ypmdr4may7im5ic4srikf1whv5f4437ra04022046wqxfi";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."gui-lib" self."slideshow-lib" self."pict-lib" self."typed-racket-lib" self."typed-racket-more" self."parser-tools-lib" self."syntax-color-lib" self."rackunit-lib" self."todo-list" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pie-a-let-mode" = self.lib.mkRacketDerivation rec {
  pname = "pie-a-let-mode";
  src = fetchgit {
    name = "pie-a-let-mode";
    url = "git://github.com/pnwamk/pie.git";
    rev = "77d183629f3d09f2d0b79a5bcd3b16e92ecf5f19";
    sha256 = "18dy1cvp0366h7qx4nwwp3gs3p0lh88dz97dkxhy97dyigsh8k0j";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."gui-lib" self."slideshow-lib" self."pict-lib" self."typed-racket-lib" self."typed-racket-more" self."parser-tools-lib" self."syntax-color-lib" self."rackunit-lib" self."todo-list" self."scribble-lib" self."racket-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pinyin" = self.lib.mkRacketDerivation rec {
  pname = "pinyin";
  src = fetchgit {
    name = "pinyin";
    url = "git://github.com/xuchunyang/pinyin.git";
    rev = "568e626f8be36c311f40d3f6771cf4f4d1cee677";
    sha256 = "00fzmjkvcljac23k58khs6bndz6gmbv9cn5jrl677b0azbm9k1w6";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pipe" = self.lib.mkRacketDerivation rec {
  pname = "pipe";
  src = fetchgit {
    name = "pipe";
    url = "https://gitlab.com/RayRacine/pipe.git";
    rev = "179b8f8ad92ced86ea8dacec607deb24aefc15aa";
    sha256 = "0hsw7gd57n43pdx61l8lbfv9y07jby4r4c4k8m9yjb8hy7fsl3w4";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."base" self."racket-doc" self."typed-racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pitfall" = self.lib.mkRacketDerivation rec {
  pname = "pitfall";
  src = fetchgit {
    name = "pitfall";
    url = "git://github.com/mbutterick/pitfall.git";
    rev = "02bbd2f6be809e8c2cf875ae8c637fbcc33d5763";
    sha256 = "004fpnp8iza4ll2aknfdij8pmnw3ak1kqdwkpdg862aayd8wr91k";
  };
  racketThinBuildInputs = [ self."draw-lib" self."with-cache" self."at-exp-lib" self."base" self."beautiful-racket-lib" self."brag" self."fontland" self."rackunit-lib" self."srfi-lite-lib" self."sugar" self."gregor" self."debug" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pk" = self.lib.mkRacketDerivation rec {
  pname = "pk";
  src = self.lib.extractPath {
    path = "pk";
    src = fetchgit {
    name = "pk";
    url = "https://gitlab.com/dustyweb/racket-pk.git";
    rev = "d659d077aa79eb0fb526b6975f5d5b693d758fb2";
    sha256 = "05izq7kgzx7gnh83nj4dxdrxd8x7cckphswrgiml977fm9fsxf9i";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pkg-build" = self.lib.mkRacketDerivation rec {
  pname = "pkg-build";
  src = fetchgit {
    name = "pkg-build";
    url = "git://github.com/racket/pkg-build.git";
    rev = "e1d6276e09a1ac6d34c501016d7ef67681647e70";
    sha256 = "16pnm58gjfwcx4q50m3l0grwfa5dhnczwwlfnckcrfk94x7v1wjc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."scribble-html-lib" self."web-server-lib" self."plt-web-lib" self."remote-shell-lib" self."at-exp-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pkg-dep-draw" = self.lib.mkRacketDerivation rec {
  pname = "pkg-dep-draw";
  src = fetchgit {
    name = "pkg-dep-draw";
    url = "git://github.com/mflatt/pkg-dep-draw.git";
    rev = "10ccd5208aab1c54cab3fe767c48b98f87f1e79d";
    sha256 = "0hlmahw8z8cvyjdwl9j5x2a0jhj3x2pikl6bfdq36vs95l6627k8";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pkg-index" = self.lib.mkRacketDerivation rec {
  pname = "pkg-index";
  src = fetchgit {
    name = "pkg-index";
    url = "git://github.com/racket/pkg-index.git";
    rev = "38f54d48b63c45925446f8ef5dc68e9cba8fdccb";
    sha256 = "1bq2c64p86f7a5ma4ws0bwvh4861x9izx3fczmkhcq8rk05bn4dl";
  };
  racketThinBuildInputs = [ self."racket-lib" self."base" self."compatibility-lib" self."net-lib" self."web-server-lib" self."bcrypt" self."s3-sync" self."plt-service-monitor" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pkg-push" = self.lib.mkRacketDerivation rec {
  pname = "pkg-push";
  src = fetchgit {
    name = "pkg-push";
    url = "git://github.com/racket/pkg-push.git";
    rev = "3fc18d8edb81b854ed98897bef925c73f68597ed";
    sha256 = "1z6g5a9kd4aysdpdan5i0n4lrpdvalri3564ka6ayyl2chdnbapz";
  };
  racketThinBuildInputs = [ self."aws" self."base" self."http" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai" = self.lib.mkRacketDerivation rec {
  pname = "plai";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plai.zip";
    sha1 = "ffc72dd33981414c3336f2880e462fcab7f2150e";
  };
  racketThinBuildInputs = [ self."plai-doc" self."plai-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-doc" = self.lib.mkRacketDerivation rec {
  pname = "plai-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plai-doc.zip";
    sha1 = "0883df07bc747ea347a4f3c8d0a962eacf4ad7ad";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."srfi-lite-lib" self."base" self."gui-lib" self."sandbox-lib" self."web-server-lib" self."plai-lib" self."at-exp-lib" self."eli-tester" self."pconvert-lib" self."rackunit-lib" self."racket-doc" self."web-server-doc" self."scribble-lib" self."drracket-tool-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-dynamic" = self.lib.mkRacketDerivation rec {
  pname = "plai-dynamic";
  src = fetchgit {
    name = "plai-dynamic";
    url = "https://pivot.cs.unb.ca/git/plai-dynamic.git";
    rev = "3e0dd86ed95e2a57a279e8334a9cf803159351ed";
    sha256 = "025lznm2bfdmg3a2a851ghqfiyr7c3bqv41s4m40bzabv3gy151l";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-lazy" = self.lib.mkRacketDerivation rec {
  pname = "plai-lazy";
  src = fetchgit {
    name = "plai-lazy";
    url = "git://github.com/mflatt/plai-lazy.git";
    rev = "814aa836ba1b981b9916fbfa9ba7b2683b0350c4";
    sha256 = "05rr92xhd8lq23pcfydr3dzvh7pg81vjn6735622fhx7kzcljl7b";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."lazy" self."plai" self."sandbox-lib" self."scheme-lib" self."srfi-lite-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-lib" = self.lib.mkRacketDerivation rec {
  pname = "plai-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plai-lib.zip";
    sha1 = "233dadb3dd054337baa0d2bfa658a0cbd8966058";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."srfi-lite-lib" self."base" self."gui-lib" self."draw-lib" self."sandbox-lib" self."web-server-lib" self."at-exp-lib" self."eli-tester" self."pconvert-lib" self."rackunit-lib" self."drracket-tool-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-math" = self.lib.mkRacketDerivation rec {
  pname = "plai-math";
  src = self.lib.extractPath {
    path = "math";
    src = fetchgit {
    name = "plai-math";
    url = "git://github.com/JamesSolum/racket_packages.git";
    rev = "a1f9cd5332c9701ded9b0c2e2888842ca1e674ca";
    sha256 = "1kls6inz79y545apblqpjp90cx7rqa9d2wxqkybslgxxlqwlhja1";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-typed" = self.lib.mkRacketDerivation rec {
  pname = "plai-typed";
  src = fetchgit {
    name = "plai-typed";
    url = "git://github.com/mflatt/plai-typed.git";
    rev = "419102db1e44b74dea9daf7a75e9b0e2b9c97d05";
    sha256 = "175kny9fr0lgwccz4gviwc8d9qi4xdg0v2hn80m76lkv9ahm6rha";
  };
  racketThinBuildInputs = [ self."base" self."plai" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-typed-s-exp-match" = self.lib.mkRacketDerivation rec {
  pname = "plai-typed-s-exp-match";
  src = fetchgit {
    name = "plai-typed-s-exp-match";
    url = "git://github.com/mflatt/plai-typed-s-exp-match.git";
    rev = "ff05b257cc8739d2f4ad8f33b65440635ab9cce0";
    sha256 = "0k2knsg04s641aw4gn5ncwbvjp973px0jrm919vxy8gdizlvri22";
  };
  racketThinBuildInputs = [ self."base" self."plai-typed" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plait" = self.lib.mkRacketDerivation rec {
  pname = "plait";
  src = fetchgit {
    name = "plait";
    url = "git://github.com/mflatt/plait.git";
    rev = "3450cfcc2754e737afde8e20d82244ddf49429b8";
    sha256 = "14jm82gnv3wyrdlsnpp64hf7y6s253hf9vi71qlh2qn59s2k4gd2";
  };
  racketThinBuildInputs = [ self."base" self."lazy" self."plai" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plaitypus" = self.lib.mkRacketDerivation rec {
  pname = "plaitypus";
  src = fetchgit {
    name = "plaitypus";
    url = "git://github.com/stamourv/plaitypus.git";
    rev = "cebf78ef1dafd5dc93485c41cf7f6eaab3e60efb";
    sha256 = "018c1x7krxv4rb14h51qmiksz3kqpd92ylrv2wvaj3zcgzkvgf5f";
  };
  racketThinBuildInputs = [ self."base" self."plai" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet" = self.lib.mkRacketDerivation rec {
  pname = "planet";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/planet.zip";
    sha1 = "a2b735dc3818499b24f3be038a39fe58cf5ec06b";
  };
  racketThinBuildInputs = [ self."planet-lib" self."planet-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-doc" = self.lib.mkRacketDerivation rec {
  pname = "planet-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/planet-doc.zip";
    sha1 = "542193f566ec23ec56cbe2d23cb3544943050b44";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."planet-lib" self."scribble-lib" self."base" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-lib" = self.lib.mkRacketDerivation rec {
  pname = "planet-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/planet-lib.zip";
    sha1 = "2c3166c387f9b2a20e4d1bae0d0fc48bffe2154a";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-test" = self.lib.mkRacketDerivation rec {
  pname = "planet-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/planet-test.zip";
    sha1 = "d7fab900c48b7e725d3995371543a6c40d3cf365";
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."eli-tester" self."planet-lib" self."rackunit-lib" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet2-example" = self.lib.mkRacketDerivation rec {
  pname = "planet2-example";
  src = fetchgit {
    name = "planet2-example";
    url = "git://github.com/jeapostrophe/planet2-example.git";
    rev = "9d9e4dc77adfc7299987a4cbbe8ce43869eec53e";
    sha256 = "0w4wz77aka2bdx20w6f735qdl4xvapyy2hwiwzx2lrs4ax8wjpj9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planning" = self.lib.mkRacketDerivation rec {
  pname = "planning";
  src = fetchgit {
    name = "planning";
    url = "git://github.com/jackfirth/planning.git";
    rev = "b3095dc1a796fc7c58e405ec6f1a3c1ce42805dc";
    sha256 = "1xdzb85c9kga01vs3spn2i2gj3dmjazg664ifnlcwzxf5mjd3r5c";
  };
  racketThinBuildInputs = [ self."snip-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."slideshow-lib" self."chess" self."fancy-app" self."point-free" self."rebellion" self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "play" = self.lib.mkRacketDerivation rec {
  pname = "play";
  src = fetchgit {
    name = "play";
    url = "git://github.com/pleiad/play.git";
    rev = "34a145ffb815110bec33a48004e8897e48d11f51";
    sha256 = "02sy2hj6hz7bmb6ckshjxqwwpdvb7di4a0lkrh9gry9vn4nh69vb";
  };
  racketThinBuildInputs = [ self."base" self."plai" self."redex" self."rackunit" self."parser-tools-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plisqin" = self.lib.mkRacketDerivation rec {
  pname = "plisqin";
  src = fetchgit {
    name = "plisqin";
    url = "git://github.com/default-kramer/plisqin.git";
    rev = "aa5c2f66e41ddede88d6cb4aa6da729e67343cfe";
    sha256 = "18c7bnk6f7jvyk1hg3hgswc9g0f16p3wk67qjjhw4ihx884kmar3";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."morsel-lib" self."at-exp-lib" self."doc-coverage" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot" = self.lib.mkRacketDerivation rec {
  pname = "plot";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot.zip";
    sha1 = "679a52f69428c4f38c64ca0f540bb21138e88f81";
  };
  racketThinBuildInputs = [ self."plot-lib" self."plot-gui-lib" self."plot-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-bestfit" = self.lib.mkRacketDerivation rec {
  pname = "plot-bestfit";
  src = fetchgit {
    name = "plot-bestfit";
    url = "git://github.com/florence/plot-bestfit.git";
    rev = "dd6ffbef2626d7cc7e6802389ce53d57d36bb21d";
    sha256 = "0mrc01wc26nrc7r1cn2nl5ikyq0q1j1f9p6dlxflpiv7d1miibys";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."plot-lib" self."plot-gui-lib" self."math-lib" self."racket-doc" self."typed-racket-doc" self."scribble-lib" self."math-doc" self."plot-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-compat" = self.lib.mkRacketDerivation rec {
  pname = "plot-compat";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot-compat.zip";
    sha1 = "77784170158609cdb9488c9aab8acf9bc333fc94";
  };
  racketThinBuildInputs = [ self."base" self."plot-gui-lib" self."draw-lib" self."plot-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-container" = self.lib.mkRacketDerivation rec {
  pname = "plot-container";
  src = fetchgit {
    name = "plot-container";
    url = "git://github.com/alex-hhh/plot-container.git";
    rev = "34bfa2cb20f967ce08fcc2fb2fd6fef2013a5bb5";
    sha256 = "0391812g8k337fdfxigyk8kxjdcf9km1pm87fhm4sgyb4qyvsdwc";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."plot-lib" self."pict-snip-lib" self."plot-gui-lib" self."snip-lib" self."gui-doc" self."pict-snip-doc" self."plot-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-doc" = self.lib.mkRacketDerivation rec {
  pname = "plot-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot-doc.zip";
    sha1 = "5f9850b78ac7277b3aee5e6bdfef8bfb2dfdee0a";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."plot-lib" self."plot-gui-lib" self."db-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."plot-compat" self."scribble-lib" self."slideshow-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "plot-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot-gui-lib.zip";
    sha1 = "c60fe6db60ead94cf3a8d9bdfd188e3686458baf";
  };
  racketThinBuildInputs = [ self."base" self."plot-lib" self."math-lib" self."gui-lib" self."snip-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-lib" = self.lib.mkRacketDerivation rec {
  pname = "plot-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot-lib.zip";
    sha1 = "39639fb2d87112decf717bd99391e9a138228e8f";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."pict-lib" self."db-lib" self."srfi-lite-lib" self."typed-racket-lib" self."typed-racket-more" self."compatibility-lib" self."math-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-test" = self.lib.mkRacketDerivation rec {
  pname = "plot-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plot-test.zip";
    sha1 = "67db42c0e238480837f05e65a88c10e2b25e9c32";
  };
  racketThinBuildInputs = [ self."base" self."plot-compat" self."plot-gui-lib" self."plot-lib" self."plot-doc" self."draw-lib" self."pict-lib" self."rackunit-lib" self."slideshow-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plplot" = self.lib.mkRacketDerivation rec {
  pname = "plplot";
  src = fetchgit {
    name = "plplot";
    url = "git://github.com/oetr/racket-plplot.git";
    rev = "fab8fe83993506b871eab9f1f6a7f2be3324c0dd";
    sha256 = "1rq8xa43n3pwvnpzn2g209918shah3z1r88xnhilyac8047rcg3i";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-build-plot" = self.lib.mkRacketDerivation rec {
  pname = "plt-build-plot";
  src = fetchgit {
    name = "plt-build-plot";
    url = "git://github.com/racket/plt-build-plot.git";
    rev = "5205f76b882e356a30258878e0d4edff4e3c6abb";
    sha256 = "0pg89l2kgj6x1skhl7744yvp0fdm00kwbi4svckk3xh1fsg91h3d";
  };
  racketThinBuildInputs = [ self."base" self."aws" self."s3-sync" self."draw-lib" self."gui-lib" self."scribble-html-lib" self."plt-web-lib" self."plt-service-monitor" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-service-monitor" = self.lib.mkRacketDerivation rec {
  pname = "plt-service-monitor";
  src = fetchgit {
    name = "plt-service-monitor";
    url = "git://github.com/racket/plt-service-monitor.git";
    rev = "1cfb827cd812361d3c348aad18625e4aa98b2ee2";
    sha256 = "1riwyjyw08pajbh352rgxjz9xvwcxwkljccdqlyip32nw8h031hf";
  };
  racketThinBuildInputs = [ self."net-lib" self."base" self."aws" self."http" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-services" = self.lib.mkRacketDerivation rec {
  pname = "plt-services";
  src = self.lib.extractPath {
    path = "pkgs/plt-services";
    src = fetchgit {
    name = "plt-services";
    url = "git://github.com/racket/racket.git";
    rev = "d590eee0c773af8a1c530db244f0f1ddb29e7871";
    sha256 = "0pnkvhc6kb4493fhw4ajw1mqln8c5467k5kmcplbw4dm4nwchd60";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-web" = self.lib.mkRacketDerivation rec {
  pname = "plt-web";
  src = self.lib.extractPath {
    path = "plt-web";
    src = fetchgit {
    name = "plt-web";
    url = "git://github.com/racket/plt-web.git";
    rev = "a964124dd29c9d855f45686480414ae5b1dc96fd";
    sha256 = "1gi4lwdz4igg7k5bgls5vpy2qgri2wy5844zbggzbbcsb1481dq5";
  };
  };
  racketThinBuildInputs = [ self."plt-web-lib" self."plt-web-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-web-doc" = self.lib.mkRacketDerivation rec {
  pname = "plt-web-doc";
  src = self.lib.extractPath {
    path = "plt-web-doc";
    src = fetchgit {
    name = "plt-web-doc";
    url = "git://github.com/racket/plt-web.git";
    rev = "a964124dd29c9d855f45686480414ae5b1dc96fd";
    sha256 = "1gi4lwdz4igg7k5bgls5vpy2qgri2wy5844zbggzbbcsb1481dq5";
  };
  };
  racketThinBuildInputs = [ self."base" self."plt-web-lib" self."racket-doc" self."scribble-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plt-web-lib" = self.lib.mkRacketDerivation rec {
  pname = "plt-web-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/plt-web-lib.zip";
    sha1 = "97b834d41ff11bd4b98e9a0a16bfbc06758d4366";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."scribble-html-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pmap" = self.lib.mkRacketDerivation rec {
  pname = "pmap";
  src = fetchgit {
    name = "pmap";
    url = "git://github.com/APOS80/pmap.git";
    rev = "e352de9bbc6735b1ca089a21490f87fc2fba5279";
    sha256 = "0zzjmba0fgb332xw7046nwdlhxngja5d651y3vr6i3brrl4jpiaj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "png-image" = self.lib.mkRacketDerivation rec {
  pname = "png-image";
  src = fetchgit {
    name = "png-image";
    url = "git://github.com/lehitoskin/png-image.git";
    rev = "2515ab0af55f3d9e8aac92aaa3bc6a9dc571f60d";
    sha256 = "15z32wsj5c2mc3vnn7g4ndchb24gx2d5yc7mz4jn75j9h6c401kj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "point-free" = self.lib.mkRacketDerivation rec {
  pname = "point-free";
  src = fetchgit {
    name = "point-free";
    url = "git://github.com/jackfirth/point-free.git";
    rev = "d294a342466d5071dd2c8f16ba9e50f9006b54af";
    sha256 = "043p1zrvidw3mv6qmwkyr36hdsdbb1wwaw3fbv2ghn4fwd2wglir";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."doc-coverage" self."cover" self."doc-coverage" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen" = self.lib.mkRacketDerivation rec {
  pname = "pollen";
  src = fetchgit {
    name = "pollen";
    url = "git://github.com/mbutterick/pollen.git";
    rev = "85ac0cdfab6dc043cfe769c98c8ee80ef710c5e8";
    sha256 = "10xsz7ib2m62d7s6qxgkvrax48phqzygjihq0qpmw4kyw3cpl5ri";
  };
  racketThinBuildInputs = [ self."base" self."txexpr" self."sugar" self."markdown" self."htdp" self."at-exp-lib" self."html-lib" self."rackjure" self."web-server-lib" self."scribble-lib" self."scribble-text-lib" self."rackunit-lib" self."gui-lib" self."string-constants-lib" self."net-lib" self."plot-gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-doc" self."plot-doc" self."scribble-doc" self."slideshow-doc" self."web-server-doc" self."drracket" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-citations-mcgill" = self.lib.mkRacketDerivation rec {
  pname = "pollen-citations-mcgill";
  src = fetchgit {
    name = "pollen-citations-mcgill";
    url = "git://github.com/sanchom/pollen-citations-mcgill.git";
    rev = "d2c871a3ee9284979f65c4662ad8d523eb9256c9";
    sha256 = "0m6s62z4phm1i5pwahbrkyj1cz3jxama3ccpja1nrn8z3rf6l62a";
  };
  racketThinBuildInputs = [ self."base" self."pollen" self."txexpr" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-component" = self.lib.mkRacketDerivation rec {
  pname = "pollen-component";
  src = fetchgit {
    name = "pollen-component";
    url = "git://github.com/leafac/pollen-component.git";
    rev = "36853a84a58e2889b0e3065d5f1357a596e3c1e6";
    sha256 = "168k5gzpcyq710c32mcvlsrbq4gz1lv1f1y3d755ci785ybm0l63";
  };
  racketThinBuildInputs = [ self."base" self."pollen" self."sugar" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-count" = self.lib.mkRacketDerivation rec {
  pname = "pollen-count";
  src = fetchgit {
    name = "pollen-count";
    url = "git://github.com/malcolmstill/pollen-count.git";
    rev = "c4da923debcf40d0558ea4cb97c8a7bd4f35f34b";
    sha256 = "123898dz12p3605zprs6bynlgimw73yqfi77dimy1bdp2kjynff4";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."txexpr" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-rock" = self.lib.mkRacketDerivation rec {
  pname = "pollen-rock";
  src = fetchgit {
    name = "pollen-rock";
    url = "git://github.com/lijunsong/pollen-rock.git";
    rev = "8107c7c1a1ca1e5ab125650f38002683b15b22c9";
    sha256 = "0rxi8ai28id1flkwz4swcbr9z5rnz4fng9694zlx6fpkw9hdxjyv";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."web-server-lib" self."pollen" self."sugar" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-tfl" = self.lib.mkRacketDerivation rec {
  pname = "pollen-tfl";
  src = fetchgit {
    name = "pollen-tfl";
    url = "git://github.com/mbutterick/pollen-tfl.git";
    rev = "e63740ce6e23a69fbff26e3eca31edded420f0b3";
    sha256 = "1nd3lpg6j8byvw1rz6wy1hrl15jwmlj1mk2cn927f7jfgj0mf6br";
  };
  racketThinBuildInputs = [ self."base" self."pollen" self."hyphenate" self."css-tools" self."txexpr" self."sugar" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pollen-tuftorial" = self.lib.mkRacketDerivation rec {
  pname = "pollen-tuftorial";
  src = fetchgit {
    name = "pollen-tuftorial";
    url = "git://github.com/mbutterick/pollen-tuftorial.git";
    rev = "c7b586afe9bb09a1bcc9f5772d734ee7dbee9eed";
    sha256 = "15y0gz01n4qg43b9bhfj3lq0mas3nmzsfl005wx6by8dw9dvzwf4";
  };
  racketThinBuildInputs = [ self."base" self."pollen" self."hyphenate" self."css-tools" self."txexpr" self."sugar" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "polysemy" = self.lib.mkRacketDerivation rec {
  pname = "polysemy";
  src = fetchgit {
    name = "polysemy";
    url = "git://github.com/jsmaniac/polysemy.git";
    rev = "c499b6e3f033f84054df7682defed8fa7f52533f";
    sha256 = "06bz73m8gc18d74krz37mlm3ra460jc1fggwv5q4w9g003ah3s43";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pop-pl" = self.lib.mkRacketDerivation rec {
  pname = "pop-pl";
  src = fetchgit {
    name = "pop-pl";
    url = "git://github.com/florence/pop-pl.git";
    rev = "758f7bff0b5e2810f85cda0b6305c4699ed4fce5";
    sha256 = "0z8b7rs6aqhdbbg8vyfzq2vgs10zfxmk5liyj82qny3wfb9dpcb4";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."pict-lib" self."rackunit-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "popl-2012-ryr-talk" = self.lib.mkRacketDerivation rec {
  pname = "popl-2012-ryr-talk";
  src = fetchgit {
    name = "popl-2012-ryr-talk";
    url = "git://github.com/rfindler/popl-2012-ryr-talk.git";
    rev = "9da05129de004cc1df0ccfbd821e8542a9155021";
    sha256 = "1fybgxk720n3kq82pzvms00bzyn0xascxc780mk5y00vncigwnaw";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."htdp-lib" self."redex-gui-lib" self."redex-lib" self."slideshow-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "poppler-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "poppler-i386-macosx";
  src = self.lib.extractPath {
    path = "poppler-i386-macosx";
    src = fetchgit {
    name = "poppler-i386-macosx";
    url = "git://github.com/soegaard/poppler-libs.git";
    rev = "dbb5cf3e6e225aa8af8abdc815734981682812bd";
    sha256 = "16ikr9ixdi8z4arj7qa324nd4p9gydvp80dh23rjg2qyyzggq1ly";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "poppler-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "poppler-win32-i386";
  src = self.lib.extractPath {
    path = "poppler-win32-i386";
    src = fetchgit {
    name = "poppler-win32-i386";
    url = "git://github.com/soegaard/poppler-libs.git";
    rev = "dbb5cf3e6e225aa8af8abdc815734981682812bd";
    sha256 = "16ikr9ixdi8z4arj7qa324nd4p9gydvp80dh23rjg2qyyzggq1ly";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "poppler-win32-x86-64" = self.lib.mkRacketDerivation rec {
  pname = "poppler-win32-x86-64";
  src = self.lib.extractPath {
    path = "poppler-win32-x86_64";
    src = fetchgit {
    name = "poppler-win32-x86-64";
    url = "git://github.com/soegaard/poppler-libs.git";
    rev = "dbb5cf3e6e225aa8af8abdc815734981682812bd";
    sha256 = "16ikr9ixdi8z4arj7qa324nd4p9gydvp80dh23rjg2qyyzggq1ly";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "poppler-x86-64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "poppler-x86-64-macosx";
  src = self.lib.extractPath {
    path = "poppler-x86_64-macosx";
    src = fetchgit {
    name = "poppler-x86-64-macosx";
    url = "git://github.com/soegaard/poppler-libs.git";
    rev = "dbb5cf3e6e225aa8af8abdc815734981682812bd";
    sha256 = "16ikr9ixdi8z4arj7qa324nd4p9gydvp80dh23rjg2qyyzggq1ly";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "port-match" = self.lib.mkRacketDerivation rec {
  pname = "port-match";
  src = fetchgit {
    name = "port-match";
    url = "git://github.com/lwhjp/port-match.git";
    rev = "71fd3e9ed4f5766c46182923b08ff6d514e838a2";
    sha256 = "1w3fawiva1zzll9adkpxazzi78va43dpjpscw65lhnj9i6s605il";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "portaudio" = self.lib.mkRacketDerivation rec {
  pname = "portaudio";
  src = fetchgit {
    name = "portaudio";
    url = "git://github.com/jbclements/portaudio.git";
    rev = "3703edda0c6b9f5ef7e7bf39b933cb1d0e9a82b5";
    sha256 = "1132wfqdapn7yswhkp7rbvc6lymqs1wgala8rnka92j6z5ms8rln";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "positional-tree-utils" = self.lib.mkRacketDerivation rec {
  pname = "positional-tree-utils";
  src = fetchgit {
    name = "positional-tree-utils";
    url = "git://github.com/v-nys/positional-tree-utils.git";
    rev = "1ef3b3d188660b4849788872d6a2b3eaf5d355df";
    sha256 = "0v61046kwmkhi9qx4a6j9svr5lqh8ryj729zmvdsrjs5jyd9gkgj";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."list-utils" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "postfix-dot-notation" = self.lib.mkRacketDerivation rec {
  pname = "postfix-dot-notation";
  src = fetchgit {
    name = "postfix-dot-notation";
    url = "git://github.com/AlexKnauth/postfix-dot-notation.git";
    rev = "584ed69de73775e261ecdb7607fc14d9790500ef";
    sha256 = "00klrvih15mnhcnpwjs99jg6i672f4bgisx0jypi8qc2anwd415s";
  };
  racketThinBuildInputs = [ self."base" self."sweet-exp" self."hygienic-reader-extension" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "postmark" = self.lib.mkRacketDerivation rec {
  pname = "postmark";
  src = fetchgit {
    name = "postmark";
    url = "git://github.com/jbclements/postmark.git";
    rev = "6204838d15c5de48389a2a45ee9158493cc76bc8";
    sha256 = "1546ry96yfglwvp6kw9sswmki33l3d52iwknaa23vfi4yxr7g8zv";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "postmark-client" = self.lib.mkRacketDerivation rec {
  pname = "postmark-client";
  src = self.lib.extractPath {
    path = "postmark";
    src = fetchgit {
    name = "postmark-client";
    url = "git://github.com/Bogdanp/racket-postmark.git";
    rev = "163b4e1344c3c402a7ccc9436f0c3123c837b824";
    sha256 = "11ipiq73y4bacdc331ghbnlghsw879llv7l6s9d1lgqdqlfp6vf0";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "postnet" = self.lib.mkRacketDerivation rec {
  pname = "postnet";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/postnet.zip";
    sha1 = "b8a714b8cedd168925c6e1de8dd7cb80fd5391da";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "power-struct" = self.lib.mkRacketDerivation rec {
  pname = "power-struct";
  src = fetchgit {
    name = "power-struct";
    url = "git://github.com/BourgondAries/power-struct.git";
    rev = "cb9c521b8d1047d9d60a688b278dee61b301b975";
    sha256 = "0d28iw3mm4n8vm840sahimqhvvfay8dmmd132g7sv7l0nigagh5m";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ppict" = self.lib.mkRacketDerivation rec {
  pname = "ppict";
  src = fetchgit {
    name = "ppict";
    url = "git://github.com/rmculpepper/ppict.git";
    rev = "5d2d5f9d0a10f0988c7ed1f1986a0a6a15dcdb77";
    sha256 = "0cdznm82f6n9lzamhd4d4ml047s99w6xf69gwwkaw446hjzgid20";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."slideshow-lib" self."racket-doc" self."scribble-lib" self."pict-doc" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ppict-slide-grid" = self.lib.mkRacketDerivation rec {
  pname = "ppict-slide-grid";
  src = fetchgit {
    name = "ppict-slide-grid";
    url = "git://github.com/takikawa/ppict-slide-grid.git";
    rev = "1e992183dbfc695882bb612bb5b8b32515adeee2";
    sha256 = "1nn164m28fvx8a92jk534kqz89wx9jwbivvypkx6fr3lm8xznrw9";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."slideshow-lib" self."unstable-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pprint" = self.lib.mkRacketDerivation rec {
  pname = "pprint";
  src = fetchgit {
    name = "pprint";
    url = "git://github.com/takikawa/pprint.plt.git";
    rev = "c85b4adcf26d3afc5b812d21b3a8f31d1fc6f853";
    sha256 = "0s4vzzp0a83dc3bh9gqss9l7d0k65yrgzaq40j79rfjln89flhp7";
  };
  racketThinBuildInputs = [ self."base" self."dherman-struct" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "predicates" = self.lib.mkRacketDerivation rec {
  pname = "predicates";
  src = fetchgit {
    name = "predicates";
    url = "git://github.com/jackfirth/predicates.git";
    rev = "ba6b82864a6bdb2b0aa42d3a493effe54d44e4e1";
    sha256 = "0lh33g9s7x8ac5q71xknnmkjp8nlc1qzyb8papxm8plq105ral94";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "prefab-predicate-compat" = self.lib.mkRacketDerivation rec {
  pname = "prefab-predicate-compat";
  src = fetchgit {
    name = "prefab-predicate-compat";
    url = "git://github.com/pnwamk/prefab-predicate-compat.git";
    rev = "7c6cc40738062f336839b1f63e9b9ceb2a80071a";
    sha256 = "0a4h2ic705cixckgy2qy48iypkhmksjhzfr1547fh9fw4wlrh0yc";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "prefetch-autocomplete" = self.lib.mkRacketDerivation rec {
  pname = "prefetch-autocomplete";
  src = fetchgit {
    name = "prefetch-autocomplete";
    url = "git://github.com/yjqww6/prefetch-autocomplete.git";
    rev = "1a25f1a64cab3c9d1e300b9a0547e2b4201fcc70";
    sha256 = "1hhw007bpgbwd4yh46zm0nybrcc9d1a7nchmcld74m67kh3468jd";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "preprocessor" = self.lib.mkRacketDerivation rec {
  pname = "preprocessor";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/preprocessor.zip";
    sha1 = "3cbe636149b538a4b03cba4ef37eef9b4886b2e0";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pretty-format" = self.lib.mkRacketDerivation rec {
  pname = "pretty-format";
  src = fetchgit {
    name = "pretty-format";
    url = "git://github.com/AlexKnauth/pretty-format.git";
    rev = "e94914aad81c71b4ccfb4b573affd58df6619888";
    sha256 = "1421a4f9d13r2pg1zr233q1rrs0d3mica78fyq1vr9p808j95npx";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pretty-graphs" = self.lib.mkRacketDerivation rec {
  pname = "pretty-graphs";
  src = fetchgit {
    name = "pretty-graphs";
    url = "git://github.com/v-nys/pretty-graphs.git";
    rev = "a525fdc779e745b222b9e3d495c9f525290fd4cc";
    sha256 = "1sh9jbi5bl8jhdx0fd28s31m080rlgj7v39ga488nc06dink0zxx";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."graph" self."pict-doc" self."pict-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "print-debug" = self.lib.mkRacketDerivation rec {
  pname = "print-debug";
  src = fetchgit {
    name = "print-debug";
    url = "git://github.com/aldis-sarja/print-debug.git";
    rev = "39fa9a7ad50099115841e1c05d7c65a4d4f8df4a";
    sha256 = "1mdkaawqzf5dm2naypw7hs85macb2fzl6cys5hzcbf4knfm7rc3y";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile" = self.lib.mkRacketDerivation rec {
  pname = "profile";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/profile.zip";
    sha1 = "2010e70534a5f952bb7c2f408f5c02862fc43d37";
  };
  racketThinBuildInputs = [ self."profile-lib" self."profile-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-doc" = self.lib.mkRacketDerivation rec {
  pname = "profile-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/profile-doc.zip";
    sha1 = "9ce1399f7ea228e6d07ca7a04411dfb8d433c5f2";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."profile-lib" self."errortrace-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-flame-graph" = self.lib.mkRacketDerivation rec {
  pname = "profile-flame-graph";
  src = fetchgit {
    name = "profile-flame-graph";
    url = "git://github.com/takikawa/racket-profile-flamegraph.git";
    rev = "1364a084256765800e83d93b0db23b2cc801d161";
    sha256 = "1szkj9z17kdm2fsqb17wj4blnkay0wfsxc2wd17fmvq0bypfylrk";
  };
  racketThinBuildInputs = [ self."base" self."pict" self."profile-lib" self."net-lib" self."data-lib" self."scribble-lib" self."racket-doc" self."profile-doc" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-lib" = self.lib.mkRacketDerivation rec {
  pname = "profile-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/profile-lib.zip";
    sha1 = "e6260a21bd7325940325d1ecc219e270d49dd45c";
  };
  racketThinBuildInputs = [ self."base" self."errortrace-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-test" = self.lib.mkRacketDerivation rec {
  pname = "profile-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/profile-test.zip";
    sha1 = "180b48ab005cdb9715b789817f00acbf2130426e";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."profile-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profj" = self.lib.mkRacketDerivation rec {
  pname = "profj";
  src = fetchgit {
    name = "profj";
    url = "git://github.com/mflatt/profj.git";
    rev = "aa20a056d7834a1e821f6c63277ee03724af9b15";
    sha256 = "0mq34fn1hxc38lrp36jbgx08c21gcvk1v8cgxapy4xhccigwcs6g";
  };
  racketThinBuildInputs = [ self."combinator-parser" self."base" self."compatibility-lib" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."htdp-lib" self."parser-tools-lib" self."scheme-lib" self."srfi-lite-lib" self."string-constants-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "progedit" = self.lib.mkRacketDerivation rec {
  pname = "progedit";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/progedit.zip";
    sha1 = "28f6ce349a1173812a3efd1c95edb569c46e43f7";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "protobj" = self.lib.mkRacketDerivation rec {
  pname = "protobj";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/protobj.zip";
    sha1 = "4e2755403b30e7746fa4ffe4688ba37c11bd2eb5";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."compatibility-lib" self."srfi-lib" self."overeasy" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "protobuf" = self.lib.mkRacketDerivation rec {
  pname = "protobuf";
  src = fetchurl {
    url = "https://bitbucket.org/chust/racket-protobuf/downloads/protobuf-1.1.3.zip";
    sha1 = "692c4439046fb158e9a8cecd9e4f5b07709c425e";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lib" self."srfi-lite-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "psd" = self.lib.mkRacketDerivation rec {
  pname = "psd";
  src = fetchgit {
    name = "psd";
    url = "git://github.com/wargrey/psd.git";
    rev = "73b16a52e0777250d02e977f7dcbd7c1d98ef772";
    sha256 = "0x6ks3iar7ph0n3zjcj9h0ryj6w706dmm5lqjzjhm0hbx66y41sk";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."draw-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "punctaffy" = self.lib.mkRacketDerivation rec {
  pname = "punctaffy";
  src = self.lib.extractPath {
    path = "punctaffy";
    src = fetchgit {
    name = "punctaffy";
    url = "git://github.com/lathe/punctaffy-for-racket.git";
    rev = "e48239631fb56eda41b90c0d0c5a2890e3ad174d";
    sha256 = "0ixnppar73f064r5i58b63a73jjws9h7gw4qaxvzri98i1qiqj7h";
  };
  };
  racketThinBuildInputs = [ self."punctaffy-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "punctaffy-lib" = self.lib.mkRacketDerivation rec {
  pname = "punctaffy-lib";
  src = self.lib.extractPath {
    path = "punctaffy-lib";
    src = fetchgit {
    name = "punctaffy-lib";
    url = "git://github.com/lathe/punctaffy-for-racket.git";
    rev = "e48239631fb56eda41b90c0d0c5a2890e3ad174d";
    sha256 = "0ixnppar73f064r5i58b63a73jjws9h7gw4qaxvzri98i1qiqj7h";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."lathe-morphisms-lib" self."parendown-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "punctaffy-test" = self.lib.mkRacketDerivation rec {
  pname = "punctaffy-test";
  src = self.lib.extractPath {
    path = "punctaffy-test";
    src = fetchgit {
    name = "punctaffy-test";
    url = "git://github.com/lathe/punctaffy-for-racket.git";
    rev = "e48239631fb56eda41b90c0d0c5a2890e3ad174d";
    sha256 = "0ixnppar73f064r5i58b63a73jjws9h7gw4qaxvzri98i1qiqj7h";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-comforts-lib" self."parendown" self."profile-lib" self."punctaffy-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pure-crypto" = self.lib.mkRacketDerivation rec {
  pname = "pure-crypto";
  src = fetchgit {
    name = "pure-crypto";
    url = "git://github.com/simmone/racket-pure-crypto.git";
    rev = "6e58a6ef06332ec300d864d0a288b0ab998374b5";
    sha256 = "1vvivj2h07n6j3w8q1vbyhb249nd77c8x8xgrfd48mc0a9dhf328";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."detail" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "puresuri" = self.lib.mkRacketDerivation rec {
  pname = "puresuri";
  src = fetchgit {
    name = "puresuri";
    url = "git://github.com/jeapostrophe/puresuri.git";
    rev = "9744e849989867e7e002507cd1dfe18ffdf5b5e3";
    sha256 = "03yhxpj3jjww2429hq0hrg2amj62asyqhlszfgm5nvbnj9vas5zj";
  };
  racketThinBuildInputs = [ self."lux" self."base" self."gui-lib" self."pict-lib" self."ppict" self."unstable-lib" self."ppict" self."gui-doc" self."pict-doc" self."racket-doc" self."slideshow-doc" self."unstable-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "puzzler" = self.lib.mkRacketDerivation rec {
  pname = "puzzler";
  src = fetchgit {
    name = "puzzler";
    url = "git://github.com/aowens-21/puzzler.git";
    rev = "be84df0049795acddf4eee0cc0225f0659df0445";
    sha256 = "0gd7jb2szh5fvafqmyk6wswfjkrk9bf7vkyx2rwb7dxgkzl1wyj6";
  };
  racketThinBuildInputs = [ self."beautiful-racket" self."brag" self."draw-lib" self."gui-lib" self."base" self."parser-tools-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pvector" = self.lib.mkRacketDerivation rec {
  pname = "pvector";
  src = fetchgit {
    name = "pvector";
    url = "git://github.com/lexi-lambda/racket-pvector.git";
    rev = "d0132809b4da6e48c3e3087dc35cda1c47565e5e";
    sha256 = "1aa82rlxp2srlmgvc8rm6njf2ccdaddj5445w76x5dw3ik42kcbk";
  };
  racketThinBuildInputs = [ self."base" self."collections" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "py-fizz" = self.lib.mkRacketDerivation rec {
  pname = "py-fizz";
  src = fetchgit {
    name = "py-fizz";
    url = "git://github.com/thoughtstem/py-fizz.git";
    rev = "46047397ab9bbac86ab15a3e6e952777f5754fdf";
    sha256 = "0v6l4c57ydbkpndsqz3lnd99412pwk11pnkj224lzyhvq1mfwj04";
  };
  racketThinBuildInputs = [ self."racket-to-python" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pydrnlp" = self.lib.mkRacketDerivation rec {
  pname = "pydrnlp";
  src = fetchgit {
    name = "pydrnlp";
    url = "https://bitbucket.org/digitalricoeur/pydrnlp.git";
    rev = "666c1e00b67c0cc1ee6b5e3fbcfbec498b3173ac";
    sha256 = "0fcc8glpj0xf9g1ahad84zzxp3kfck9q5nh9qji34hndg7vpg8i8";
  };
  racketThinBuildInputs = [ self."base" self."ricoeur-kernel" self."ricoeur-tei-utils" self."adjutor" self."python-tokenizer" self."math-lib" self."pict-lib" self."draw-lib" self."typed-racket-lib" self."typed-racket-more" self."reprovide-lang" self."db-lib" self."sql" self."gregor-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."markdown" self."rackunit-typed" self."_-exp" self."at-exp-lib" self."rackjure" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "python" = self.lib.mkRacketDerivation rec {
  pname = "python";
  src = fetchgit {
    name = "python";
    url = "git://github.com/pedropramos/PyonR.git";
    rev = "16edd14f3950fd5a01f8b0237e023536ef48d17b";
    sha256 = "146wvp53liz3dgvkdn9gddqqp8fnb9arvwbbnbrqz6kkl5y4dqj1";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools" self."compatibility-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "python-tokenizer" = self.lib.mkRacketDerivation rec {
  pname = "python-tokenizer";
  src = fetchgit {
    name = "python-tokenizer";
    url = "git://github.com/jbclements/python-tokenizer.git";
    rev = "beadda52525c78f4b3aa0c8adcf42bf5e1033c5a";
    sha256 = "1qgddyrn1qg3w51200rg7jvghfjv4mh2w156s8d48p2qg0w19z7p";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."data-lib" self."while-loop" self."at-exp-lib" self."parser-tools-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "qiniu-sdk" = self.lib.mkRacketDerivation rec {
  pname = "qiniu-sdk";
  src = fetchgit {
    name = "qiniu-sdk";
    url = "git://github.com/MatrixForChange/qiniu-sdk.git";
    rev = "27ca32071cd03a1dc955ec396efa120f0d4b2759";
    sha256 = "1v08l8lcfnycfsxqrn50ssij5cfi5hx197df49n68fibx30rvx13";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "qresults-list" = self.lib.mkRacketDerivation rec {
  pname = "qresults-list";
  src = fetchgit {
    name = "qresults-list";
    url = "git://github.com/alex-hhh/qresults-list.git";
    rev = "b680a09a8e83cc72fb306e3d9a8ebaff91a7040d";
    sha256 = "1qv1aq4cq9bb2czq1fl88m15q99ylcgan5yv64qqpb2xriil7ni3";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quad" = self.lib.mkRacketDerivation rec {
  pname = "quad";
  src = fetchgit {
    name = "quad";
    url = "git://github.com/mbutterick/quad.git";
    rev = "9f2649279194a6eb895e1c2d2be8b4719b10e911";
    sha256 = "1hvrrffhwzjnzv3jk19lgxjnv04c6f3mpdn35r3d0r2sg0z0jwdd";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."beautiful-racket-lib" self."fontland" self."hyphenate" self."pitfall" self."pollen" self."rackunit-lib" self."sugar" self."txexpr" self."markdown" self."pict-lib" self."debug" self."words" self."draw-lib" self."draw-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quad-tree" = self.lib.mkRacketDerivation rec {
  pname = "quad-tree";
  src = self.lib.extractPath {
    path = "quad-tree";
    src = fetchgit {
    name = "quad-tree";
    url = "git://github.com/dented42/racket-quad-tree.git";
    rev = "2cdb598e6c79e8499e545abc078d6f9a572ca8b0";
    sha256 = "1j8227lk3my4v86pjlz3dakjqfrmad6b38nlw0saskb04vipc7kg";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "qualified-in" = self.lib.mkRacketDerivation rec {
  pname = "qualified-in";
  src = fetchgit {
    name = "qualified-in";
    url = "git://github.com/michaelmmacleod/qualified-in.git";
    rev = "779feda6a5fe30ff861971c894ae4a301c334150";
    sha256 = "1s66il35nz1kk7y3mqkrl7amdm020yvjixgg7mdv9hafz3pxm7dh";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quickcheck" = self.lib.mkRacketDerivation rec {
  pname = "quickcheck";
  src = fetchgit {
    name = "quickcheck";
    url = "git://github.com/ifigueroap/racket-quickcheck.git";
    rev = "7b1c68b059260ee41c306d7829569188901c8dc0";
    sha256 = "1j8jq7xdgby10adhqsnmnc9waf4myhjpsa945hy8lsjncwpbi3ss";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."doc-coverage" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript" = self.lib.mkRacketDerivation rec {
  pname = "quickscript";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/quickscript.zip";
    sha1 = "5dfed92f972f61eb7b780f06c205cb74bba14678";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."scribble-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript-extra" = self.lib.mkRacketDerivation rec {
  pname = "quickscript-extra";
  src = fetchgit {
    name = "quickscript-extra";
    url = "git://github.com/Metaxal/quickscript-extra.git";
    rev = "e7d3e9aa210c4fcfae1a48f7a1808facb40f8926";
    sha256 = "1yw7kn9g48bbnmk4ksa7hgc1r3fmblw998lpz76s30fq3khi2g0i";
  };
  racketThinBuildInputs = [ self."base" self."quickscript" self."at-exp-lib" self."drracket" self."gui-lib" self."pict-lib" self."racket-index" self."scribble-lib" self."srfi-lite-lib" self."web-server-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript-test" = self.lib.mkRacketDerivation rec {
  pname = "quickscript-test";
  src = fetchgit {
    name = "quickscript-test";
    url = "git://github.com/Metaxal/quickscript-test.git";
    rev = "eed8b429056b96a66b161228a6a45ccae39b5298";
    sha256 = "096isxl6v82kdqjpg2wgmdhklskiwxp2vwayv2b0nn4ikzr8imql";
  };
  racketThinBuildInputs = [ self."drracket-test" self."gui-lib" self."quickscript" self."rackunit-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quote-bad" = self.lib.mkRacketDerivation rec {
  pname = "quote-bad";
  src = fetchgit {
    name = "quote-bad";
    url = "git://github.com/AlexKnauth/quote-bad.git";
    rev = "f7b81540acad204535b993806aca04a4692ec4d5";
    sha256 = "0arpr40ffhfwczsm9rxa8bw671fpagiwmyniq7gczqq17nmksbha";
  };
  racketThinBuildInputs = [ self."base" self."pconvert-lib" self."unstable-lib" self."hygienic-quote-lang" self."rackunit-lib" self."unstable-macro-testing-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r-cade" = self.lib.mkRacketDerivation rec {
  pname = "r-cade";
  src = fetchgit {
    name = "r-cade";
    url = "git://github.com/massung/r-cade.git";
    rev = "37d4ce347784a9f22f76f78d5a6743c87d12b7dc";
    sha256 = "1vfasya9wb59pjlsjqv3vz4yybj2ixc3ar5y2anxcnhrgyzy77qm";
  };
  racketThinBuildInputs = [ self."base" self."csfml" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r-lexer" = self.lib.mkRacketDerivation rec {
  pname = "r-lexer";
  src = fetchgit {
    name = "r-lexer";
    url = "git://github.com/LeifAndersen/racket-r-lexer.git";
    rev = "0f19dd7364b69507a6f5d41ea4d77f85b24d5449";
    sha256 = "13vvp9x2h2zzkkria9bvml585a39chx73y96ihv2wy6dhkx41h16";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."parser-tools-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r-linq" = self.lib.mkRacketDerivation rec {
  pname = "r-linq";
  src = fetchgit {
    name = "r-linq";
    url = "git://github.com/trajafri/r-linq.git";
    rev = "f7a9a0162fafa4c1589d0ccc48a7f96cbd13d94f";
    sha256 = "1ddy1wgiczmw1v6xjw00calpgdb7il4n094lijvvk6i4pvcpjf46";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs" = self.lib.mkRacketDerivation rec {
  pname = "r5rs";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r5rs.zip";
    sha1 = "8319e97caa3716986f26f5c55efffc14d03c10b5";
  };
  racketThinBuildInputs = [ self."r5rs-lib" self."r5rs-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs-doc" = self.lib.mkRacketDerivation rec {
  pname = "r5rs-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r5rs-doc.zip";
    sha1 = "94144728630441dc6ea77e59adad12ed48fd36c6";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."scribble-lib" self."r5rs-lib" self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs-lib" = self.lib.mkRacketDerivation rec {
  pname = "r5rs-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r5rs-lib.zip";
    sha1 = "d629173814e093ecb7a164fee6b25a16a8d47beb";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs" = self.lib.mkRacketDerivation rec {
  pname = "r6rs";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r6rs.zip";
    sha1 = "1a9101d91604d7025d0e48da33b41712f81b42f2";
  };
  racketThinBuildInputs = [ self."r6rs-lib" self."r6rs-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-doc" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r6rs-doc.zip";
    sha1 = "38a969d8cd6bc9c152ca45e40ed9a80844f5b95d";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."racket-index" self."base" self."scribble-lib" self."r6rs-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-lib" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r6rs-lib.zip";
    sha1 = "c13400a3faa2cd325996fd3c95c1241973a6d1fd";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."r5rs-lib" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-test" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/r6rs-test.zip";
    sha1 = "54a1e80f5634a521bb4169ebd535639261b7bf0f";
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r7rs" = self.lib.mkRacketDerivation rec {
  pname = "r7rs";
  src = self.lib.extractPath {
    path = "r7rs";
    src = fetchgit {
    name = "r7rs";
    url = "git://github.com/lexi-lambda/racket-r7rs.git";
    rev = "5834ec6e66f63c61589130aaebd0f25ab3eefc2b";
    sha256 = "0fn8rmb7yi9bj371l0jlargd0nvk4i8g0i3rv4xskwi3s08sff0k";
  };
  };
  racketThinBuildInputs = [ self."base" self."r7rs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r7rs-lib" = self.lib.mkRacketDerivation rec {
  pname = "r7rs-lib";
  src = self.lib.extractPath {
    path = "r7rs-lib";
    src = fetchgit {
    name = "r7rs-lib";
    url = "git://github.com/lexi-lambda/racket-r7rs.git";
    rev = "5834ec6e66f63c61589130aaebd0f25ab3eefc2b";
    sha256 = "0fn8rmb7yi9bj371l0jlargd0nvk4i8g0i3rv4xskwi3s08sff0k";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."r5rs-lib" self."r6rs-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raart" = self.lib.mkRacketDerivation rec {
  pname = "raart";
  src = fetchgit {
    name = "raart";
    url = "git://github.com/jeapostrophe/raart.git";
    rev = "9d82f2f8ad0052c2f4a6a75a00d957b9806f33df";
    sha256 = "0yci5m8zf2xy722c10xf9ka9v8r1v65r7q9sfiyhydxsfm3rxfc4";
  };
  racketThinBuildInputs = [ self."lux" self."unix-signals" self."reprovide-lang" self."ansi" self."struct-define" self."base" self."sandbox-lib" self."htdp-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackcheck" = self.lib.mkRacketDerivation rec {
  pname = "rackcheck";
  src = fetchgit {
    name = "rackcheck";
    url = "git://github.com/Bogdanp/rackcheck.git";
    rev = "0466f44978ea1177764300be611eb577e85c490e";
    sha256 = "16dina6s8lxm15kpz3gmi6i9n62x78aylwa81fl5xxjyqm26g1z4";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."rackunit-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackdis" = self.lib.mkRacketDerivation rec {
  pname = "rackdis";
  src = fetchgit {
    name = "rackdis";
    url = "git://github.com/eu90h/rackdis.git";
    rev = "975aeb46b6432d2359fb1c625f69ae5b97f450d1";
    sha256 = "0qsrswz1dm1dsp0rd7b1257lpkr37cgg2mizzciy1317qh1fvfwb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-benchmarks" = self.lib.mkRacketDerivation rec {
  pname = "racket-benchmarks";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-benchmarks.zip";
    sha1 = "68d8fdb3416f467fe758d8441dc2d671ca940289";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."r5rs-lib" self."scheme-lib" self."racket-test" self."typed-racket-lib" self."plot" self."draw-lib" self."gui-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-build-guide" = self.lib.mkRacketDerivation rec {
  pname = "racket-build-guide";
  src = self.lib.extractPath {
    path = "pkgs/racket-build-guide";
    src = fetchgit {
    name = "racket-build-guide";
    url = "git://github.com/racket/racket.git";
    rev = "d590eee0c773af8a1c530db244f0f1ddb29e7871";
    sha256 = "0pnkvhc6kb4493fhw4ajw1mqln8c5467k5kmcplbw4dm4nwchd60";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."scribble-doc" self."distro-build-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-cheat" = self.lib.mkRacketDerivation rec {
  pname = "racket-cheat";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-cheat.zip";
    sha1 = "7903f901eddfeca2d7406a52344edd1813bed26e";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."db-doc" self."db-lib" self."drracket" self."net-doc" self."net-lib" self."parser-tools-doc" self."parser-tools-lib" self."pict-doc" self."pict-lib" self."racket-doc" self."sandbox-lib" self."slideshow-doc" self."slideshow-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-chipmunk" = self.lib.mkRacketDerivation rec {
  pname = "racket-chipmunk";
  src = fetchgit {
    name = "racket-chipmunk";
    url = "git://github.com/thoughtstem/racket-chipmunk.git";
    rev = "152c9c4758f59ade9db01614e89e946eb39de168";
    sha256 = "1bwrx8q84lkzrjb2irc70ld9g267062klh84cysdw8fbr7m2bc2k";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-cord" = self.lib.mkRacketDerivation rec {
  pname = "racket-cord";
  src = fetchgit {
    name = "racket-cord";
    url = "git://github.com/nitros12/racket-cord.git";
    rev = "54dcbf3d3b07b4630fb70b1ac43660cfbcc0b582";
    sha256 = "06r9964slkrdaf528zy7z5f3rk97l99d38zd1znff8vw2h43f64l";
  };
  racketThinBuildInputs = [ self."base" self."simple-http" self."rfc6455" self."rackunit-lib" self."html-parsing" self."srfi-lite-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-doc" = self.lib.mkRacketDerivation rec {
  pname = "racket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-doc.zip";
    sha1 = "c9aa49f9f28e5a1b409b4b1162dbf6e9563da5d8";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."net-lib" self."sandbox-lib" self."scribble-lib" self."racket-index" self."at-exp-lib" self."rackunit-lib" self."serialize-cstruct-lib" self."cext-lib" self."compiler-lib" self."math-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-dogstatsd" = self.lib.mkRacketDerivation rec {
  pname = "racket-dogstatsd";
  src = fetchgit {
    name = "racket-dogstatsd";
    url = "git://github.com/DarrenN/racket-dogstatsd.git";
    rev = "164ec431a98689b111495bad638313b219e3b0b2";
    sha256 = "0xavvywb89ypj81w98kz2msvbrh40s51lq60kna2saqbfq2dbgzi";
  };
  racketThinBuildInputs = [ self."base" self."threading" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-graphviz" = self.lib.mkRacketDerivation rec {
  pname = "racket-graphviz";
  src = fetchgit {
    name = "racket-graphviz";
    url = "git://github.com/pykello/racket-graphviz.git";
    rev = "9486fa524e22e2a04ae20a36b0c1c426716981b5";
    sha256 = "0nlfh8gvycxyj2r2fk3kibi4mlkc36d1gppp2i1s6albiaali5pa";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."draw-lib" self."metapict" self."scribble-lib" self."pict-doc" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-i386-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-i386-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/3787f833a9e20aa38be345be3f57a420f63a6523/racket-i386-macosx-2.zip";
    sha1 = "3787f833a9e20aa38be345be3f57a420f63a6523";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-i386-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-i386-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-i386-macosx-3.zip";
    sha1 = "a507fdb42ed4db9340cc1914676dcd3b834f7a93";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-immutable" = self.lib.mkRacketDerivation rec {
  pname = "racket-immutable";
  src = fetchgit {
    name = "racket-immutable";
    url = "git://github.com/AlexKnauth/racket-immutable.git";
    rev = "61abb43c1c47c3b2a48b154406004d6b8c348913";
    sha256 = "1k39amql5iwspj1g0961hxi7yg44rvj9bnh8prigi9svk7fvz2js";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-index" = self.lib.mkRacketDerivation rec {
  pname = "racket-index";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-index.zip";
    sha1 = "c97bab373c60ddf5d4eb24ef741224bf6d69e4ea";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."scheme-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-lambda-runtime" = self.lib.mkRacketDerivation rec {
  pname = "racket-lambda-runtime";
  src = fetchgit {
    name = "racket-lambda-runtime";
    url = "git://github.com/johnnyodonnell/racket-lambda-runtime.git";
    rev = "2a8410a11e93bf9371eac6f90a37c582ef5e1897";
    sha256 = "0rn8nc4ih4kvk5dcckbzxywv60dh02mwhc0mw0dkwnmsb2kb2m2f";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-lang-org" = self.lib.mkRacketDerivation rec {
  pname = "racket-lang-org";
  src = fetchgit {
    name = "racket-lang-org";
    url = "git://github.com/racket/racket-lang-org.git";
    rev = "dccc24246dc0a70f2f35d0f52356fb962ae3750b";
    sha256 = "19azir0703jvsqzrp1xy06zy54fsgpl87c229ii7m4562qlm7iq0";
  };
  racketThinBuildInputs = [ self."graph" self."gui-lib" self."base" self."plt-web-lib" self."at-exp-lib" self."net-lib" self."racket-index" self."scribble-lib" self."syntax-color-lib" self."plot-gui-lib" self."plot-lib" self."math-lib" self."pollen" self."css-tools" self."sugar" self."txexpr" self."gregor-lib" self."frog" self."rackunit-lib" self."pict-lib" self."draw-lib" self."s3-sync" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-langserver" = self.lib.mkRacketDerivation rec {
  pname = "racket-langserver";
  src = fetchgit {
    name = "racket-langserver";
    url = "git://github.com/jeapostrophe/racket-langserver.git";
    rev = "b283c2baf65bf3122bcc46b26206934bdabbd5bd";
    sha256 = "07jgwd579ja413r0lj2pncaqh3qsfdajmqkb9iibx7g8n27112b0";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."data-lib" self."drracket-tool-lib" self."gui-lib" self."syntax-color-lib" self."chk" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-language-server" = self.lib.mkRacketDerivation rec {
  pname = "racket-language-server";
  src = fetchgit {
    name = "racket-language-server";
    url = "git://github.com/theia-ide/racket-language-server.git";
    rev = "e397a130676504fc8b053e6b1f48d49b77b9ad98";
    sha256 = "1jczksisnrx49kbdw8dscdj7w677gjqdqz5zmfbcfrp9ias8pscv";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."drracket-tool-lib" self."gui-lib" self."scribble-lib" self."syntax-color-lib" self."at-exp-lib" self."data-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-locale" = self.lib.mkRacketDerivation rec {
  pname = "racket-locale";
  src = fetchgit {
    name = "racket-locale";
    url = "git://github.com/johnstonskj/racket-locale.git";
    rev = "4381d42d76548b6b52522349955be55ee46e3700";
    sha256 = "0i90x4rm9ng0yfick7wiz1dyqx0hmjdlpxvv7v834dkcd31s72vl";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-index" self."gregor-lib" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-poppler" = self.lib.mkRacketDerivation rec {
  pname = "racket-poppler";
  src = fetchgit {
    name = "racket-poppler";
    url = "git://github.com/soegaard/racket-poppler.git";
    rev = "74799859c528e9b1b3dff5c796d6393f5593affc";
    sha256 = "14pv5i7nn5b7k1byxy2py60dv9nkbqpks9m2c9p68c2km49grl3g";
  };
  racketThinBuildInputs = [ self."draw-lib" self."slideshow-lib" self."web-server-lib" self."base" self."pict" self."poppler-x86-64-macosx" self."poppler-i386-macosx" self."poppler-win32-x86-64" self."poppler-win32-i386" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."draw-doc" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-ppc-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-ppc-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/f93224b18a5e9a397a5c1347f3575d37ca2047ce/racket-ppc-macosx-2.zip";
    sha1 = "f93224b18a5e9a397a5c1347f3575d37ca2047ce";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-ppc-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-ppc-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-ppc-macosx-3.zip";
    sha1 = "0aba8d1a262be8fbaa3ba3c0f7067aeeded2ee6d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-processing" = self.lib.mkRacketDerivation rec {
  pname = "racket-processing";
  src = fetchgit {
    name = "racket-processing";
    url = "git://github.com/thoughtstem/racket-processing.git";
    rev = "c4c51b528fa10fe69f89cc7b7c27bb3388ad11c7";
    sha256 = "0q8y6qqz3xk5fsibiqs92a8iziv3zd21rklpnfrann7bb7xi1m95";
  };
  racketThinBuildInputs = [ self."racket-to" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-quandl" = self.lib.mkRacketDerivation rec {
  pname = "racket-quandl";
  src = fetchgit {
    name = "racket-quandl";
    url = "git://github.com/malcolmstill/racket-quandl.git";
    rev = "2bc231f7981dfcd663c87ce46b4ff0876723a7ef";
    sha256 = "1jhm0almw4b2q3bn1wq49hqr5b8b11v6jp4kq9n92wr75wpnqp1h";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-rackunit-grade" = self.lib.mkRacketDerivation rec {
  pname = "racket-rackunit-grade";
  src = fetchgit {
    name = "racket-rackunit-grade";
    url = "git://github.com/ifigueroap/racket-rackunit-grade.git";
    rev = "92526d7ced3b4cf7b5323752f20d8f36752e69b6";
    sha256 = "1yh3xz8j01i0chlxaqqirpcrh6ynlbknhfz1w7j7df8hjyqqkdmp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."doc-coverage" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-raylib-2d" = self.lib.mkRacketDerivation rec {
  pname = "racket-raylib-2d";
  src = fetchgit {
    name = "racket-raylib-2d";
    url = "git://github.com/arvyy/racket-raylib-2d.git";
    rev = "2f0b05f37e6bd81cf4246116c7d32f2744dc53c0";
    sha256 = "155p8wppqvgfdksmsn566rglb0mnr5h0dhj4nf9dfirkg7yp7mb8";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-route-match" = self.lib.mkRacketDerivation rec {
  pname = "racket-route-match";
  src = fetchgit {
    name = "racket-route-match";
    url = "git://github.com/Junker/racket-route-match.git";
    rev = "c9800e602f0e58bf6e0273d7dbdb86d28f9047cb";
    sha256 = "0d4y7668a0lkk0569bc14qgil1a465fjmpckzaxn45krg97am1y9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-scaffold" = self.lib.mkRacketDerivation rec {
  pname = "racket-scaffold";
  src = fetchgit {
    name = "racket-scaffold";
    url = "git://github.com/johnstonskj/racket-scaffold.git";
    rev = "8613daf76e46fbf320de1230565e67de17fb92f5";
    sha256 = "0qg99k46aikk5jzsgnvgpk59fdg1b95i7d4afv7rs92pzyd9vvdf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-index" self."dali" self."scribble-lib" self."scribble-doc" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-school-mystery-languages" = self.lib.mkRacketDerivation rec {
  pname = "racket-school-mystery-languages";
  src = fetchgit {
    name = "racket-school-mystery-languages";
    url = "git://github.com/justinpombrio/RacketSchool.git";
    rev = "757295f338d9d3937046782f9c910f8e39d42ef8";
    sha256 = "143jgb0v464wvm88y42d38ydw7d9kniylc8qlj75w4lw23w2w9k9";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-spider" = self.lib.mkRacketDerivation rec {
  pname = "racket-spider";
  src = fetchgit {
    name = "racket-spider";
    url = "git://github.com/Syntacticlosure/racket-spider.git";
    rev = "e85c669f23e96944a7f9a42b29872b8e59a65c74";
    sha256 = "0xksjihil1i3njdbp6adi664rrck097s2fwymkn8lb0dpndlk3bc";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-test" = self.lib.mkRacketDerivation rec {
  pname = "racket-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-test.zip";
    sha1 = "86da3058feb2167327b63520c45bbf13d6fd4f05";
  };
  racketThinBuildInputs = [ self."net-test+racket-test" self."compiler-lib" self."sandbox-lib" self."compatibility-lib" self."eli-tester" self."planet-lib" self."net-lib" self."serialize-cstruct-lib" self."cext-lib" self."pconvert-lib" self."racket-test-core" self."web-server-lib" self."rackunit-lib" self."at-exp-lib" self."option-contract-lib" self."srfi-lib" self."scribble-lib" self."racket-index" self."scheme-lib" self."base" self."data-lib" ];
  circularBuildInputs = [ "racket-test" "net-test" ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-test-core" = self.lib.mkRacketDerivation rec {
  pname = "racket-test-core";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-test-core.zip";
    sha1 = "0fd6d08f1c9835e27a895baccdb362985c75ad2a";
  };
  racketThinBuildInputs = [ self."base" self."zo-lib" self."at-exp-lib" self."serialize-cstruct-lib" self."dynext-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-test-extra" = self.lib.mkRacketDerivation rec {
  pname = "racket-test-extra";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-test-extra.zip";
    sha1 = "17aa9fb771111203fbe3e6f483d46513271e038e";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."scheme-lib" self."rackunit-lib" self."serialize-cstruct-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-to" = self.lib.mkRacketDerivation rec {
  pname = "racket-to";
  src = fetchgit {
    name = "racket-to";
    url = "git://github.com/thoughtstem/racket-to.git";
    rev = "c76caf3721c09d68c5871a64481b15be72293259";
    sha256 = "0nsn9gn2ffxks3q0xn9iw50r4k5cdzm2bmbpnyzc2qij4wgxcild";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-to-python" = self.lib.mkRacketDerivation rec {
  pname = "racket-to-python";
  src = fetchgit {
    name = "racket-to-python";
    url = "git://github.com/thoughtstem/racket-to-python.git";
    rev = "5726abfb20b8411d05482d07ff384ecae779a010";
    sha256 = "1mpnm177mw36y5q6pglcfxfrsy08v1nn383b3fks0lljlm1m7r2z";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-i386";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/4a8413377a054b590354e89ee4ed027fb1c25668/racket-win32-i386.zip";
    sha1 = "4a8413377a054b590354e89ee4ed027fb1c25668";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-i386-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-i386-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/bac346e6e63990a969d2355a15b38bec5118bc06/racket-win32-i386-2.zip";
    sha1 = "bac346e6e63990a969d2355a15b38bec5118bc06";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-i386-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-i386-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-win32-i386-3.zip";
    sha1 = "8e021b4d7a93f75226c96d88e9c85c5fa3f9633d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-x86_64";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/7a7cf948c1b01b4636e4dd95582d268d9bcdc612/racket-win32-x86_64.zip";
    sha1 = "7a7cf948c1b01b4636e4dd95582d268d9bcdc612";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-x86_64-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-x86_64-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/671d3bb7b9f1c3d442e9fcc327cfe126cbc01dcb/racket-win32-x86_64-2.zip";
    sha1 = "671d3bb7b9f1c3d442e9fcc327cfe126cbc01dcb";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-win32-x86_64-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-win32-x86_64-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-win32-x86_64-3.zip";
    sha1 = "462160907353168f2e722c4407183d202cc8d760";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-x86_64-linux-natipkg-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-x86_64-linux-natipkg-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/36682b48c97f744b2ac425e630596e1a0254478f/racket-x86_64-linux-natipkg-2.zip";
    sha1 = "36682b48c97f744b2ac425e630596e1a0254478f";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-x86_64-linux-natipkg-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-x86_64-linux-natipkg-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-x86_64-linux-natipkg-3.zip";
    sha1 = "4512d66f0609d6de12c68d3207741767f69f17ea";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-x86_64-macosx-2" = self.lib.mkRacketDerivation rec {
  pname = "racket-x86_64-macosx-2";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/22c22e199c2a12502a1d8ace9b2bcf303b8e764b/racket-x86_64-macosx-2.zip";
    sha1 = "22c22e199c2a12502a1d8ace9b2bcf303b8e764b";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-x86_64-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-x86_64-macosx-3";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racket-x86_64-macosx-3.zip";
    sha1 = "b595965778f1a08b426898b89f23e1ff3b652dd9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketcon-2018-web-devel-workshop" = self.lib.mkRacketDerivation rec {
  pname = "racketcon-2018-web-devel-workshop";
  src = fetchgit {
    name = "racketcon-2018-web-devel-workshop";
    url = "git://github.com/jessealama/racketcon-2018-web-devel-workshop.git";
    rev = "e377a8f4fd9d6ef3b097ef1507ff3e16e0e260dc";
    sha256 = "0qk11h9d3rgzr5wjk357xpxkzs51zgwclwdkayz18fxszjnm2gq5";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."txexpr" self."http" self."html-parsing" self."css-expr" self."web-server-lib" self."net-cookies-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketeer" = self.lib.mkRacketDerivation rec {
  pname = "racketeer";
  src = fetchgit {
    name = "racketeer";
    url = "git://github.com/miraleung/racketeer";
    rev = "e3f703a46db1d97acbca361ebad3a21b3d4c2601";
    sha256 = "06d64k4igwkn2rs98ivyi168id2qj68n19ah8s2xayfc0fs6c6xi";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."htdp-lib" self."rackunit-lib" self."sandbox-lib" self."syntax-color-lib" self."wxme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketmq" = self.lib.mkRacketDerivation rec {
  pname = "racketmq";
  src = fetchgit {
    name = "racketmq";
    url = "git://github.com/tonyg/racketmq.git";
    rev = "ac4f15325fed55e944bbb7daa0a4642ed0cbf843";
    sha256 = "1pvfd6iqrdi38dbxiz1b1kpnflqrrs94wkwrj19iliba44xdygg1";
  };
  racketThinBuildInputs = [ self."base" self."syndicate" self."web-server-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketscript" = self.lib.mkRacketDerivation rec {
  pname = "racketscript";
  src = self.lib.extractPath {
    path = "racketscript";
    src = fetchgit {
    name = "racketscript";
    url = "git://github.com/vishesh/racketscript.git";
    rev = "3358bfe700d0478130ed0e0182f893a31dd96950";
    sha256 = "0y8cvm9clbgrfsx1aar95454af0gqxqybkfcgak59rmd9inwnvcr";
  };
  };
  racketThinBuildInputs = [ self."base" self."racketscript-compiler" self."racketscript-extras" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketscript-compiler" = self.lib.mkRacketDerivation rec {
  pname = "racketscript-compiler";
  src = self.lib.extractPath {
    path = "racketscript-compiler";
    src = fetchgit {
    name = "racketscript-compiler";
    url = "git://github.com/vishesh/racketscript.git";
    rev = "3358bfe700d0478130ed0e0182f893a31dd96950";
    sha256 = "0y8cvm9clbgrfsx1aar95454af0gqxqybkfcgak59rmd9inwnvcr";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."threading" self."graph-lib" self."anaphoric" self."base" self."typed-racket-lib" self."typed-racket-more" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketscript-extras" = self.lib.mkRacketDerivation rec {
  pname = "racketscript-extras";
  src = self.lib.extractPath {
    path = "racketscript-extras";
    src = fetchgit {
    name = "racketscript-extras";
    url = "git://github.com/vishesh/racketscript.git";
    rev = "3358bfe700d0478130ed0e0182f893a31dd96950";
    sha256 = "0y8cvm9clbgrfsx1aar95454af0gqxqybkfcgak59rmd9inwnvcr";
  };
  };
  racketThinBuildInputs = [ self."base" self."racketscript-compiler" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racketui" = self.lib.mkRacketDerivation rec {
  pname = "racketui";
  src = fetchgit {
    name = "racketui";
    url = "git://github.com/nadeemabdulhamid/racketui.git";
    rev = "059fda3fa60b84a390fabe764e12edbdfd079190";
    sha256 = "0v2wx5jm98rw0v3j4jj80xqvs0r23403pb0nabq8fcjqlmhj68a4";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."htdp-lib" self."srfi-lite-lib" self."web-server-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackjure" = self.lib.mkRacketDerivation rec {
  pname = "rackjure";
  src = fetchgit {
    name = "rackjure";
    url = "git://github.com/greghendershott/rackjure.git";
    rev = "9422246972705cfa55c773c39383a33b531507d9";
    sha256 = "0k8inzd1jpai9rw8xbrwrcghmpgjnwf88dnw8i2088bgrn5xr2g7";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."threading-lib" self."rackunit-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" self."threading-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racklog" = self.lib.mkRacketDerivation rec {
  pname = "racklog";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/racklog.zip";
    sha1 = "524d70034ade1df594939d79cabd2912337c2c42";
  };
  racketThinBuildInputs = [ self."base" self."datalog" self."eli-tester" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackonsole" = self.lib.mkRacketDerivation rec {
  pname = "rackonsole";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/rackonsole.zip";
    sha1 = "9cb037f857243bef20c19ee280af458659eca731";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."charterm" self."gdbdump" self."compatibility-lib" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackpgmp" = self.lib.mkRacketDerivation rec {
  pname = "rackpgmp";
  src = self.lib.extractPath {
    path = "rackpgmp";
    src = fetchgit {
    name = "rackpgmp";
    url = "git://github.com/wilbowma/pgmp.git";
    rev = "405316e54f194a5d8cbf968bbcb96a0ef3ea70a3";
    sha256 = "0p1narya41vjmk369qinx11rjzbg8hsixpcafmi1c8plwda3rv7p";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."errortrace-doc" self."scribble-lib" self."sandbox-lib" self."errortrace-lib" self."rackunit-lib" self."r6rs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackterm" = self.lib.mkRacketDerivation rec {
  pname = "rackterm";
  src = fetchgit {
    name = "rackterm";
    url = "git://github.com/willghatch/rackterm.git";
    rev = "56f08b3acac1cd7f014625439bb1b980b3f91364";
    sha256 = "0znawasm6gf8bnc547ikbsvm9nzmnklca6qw8kd1mrdwc7vsmzbb";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."rackunit-lib" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit" = self.lib.mkRacketDerivation rec {
  pname = "rackunit";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit.zip";
    sha1 = "2434580100cbc677305c21f5519accf6294b346a";
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."rackunit-doc" self."rackunit-gui" self."rackunit-plugin-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-abbrevs" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-abbrevs";
  src = fetchgit {
    name = "rackunit-abbrevs";
    url = "git://github.com/bennn/rackunit-abbrevs.git";
    rev = "507e8b64307d8e14fd66adc1ef89833a102f75b9";
    sha256 = "12yz7ysrv62j2mvdmnw12wwcbx63p7jvfxbzwjb15pphxq9zxb89";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-chk" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-chk";
  src = fetchgit {
    name = "rackunit-chk";
    url = "git://github.com/jeapostrophe/rackunit-chk.git";
    rev = "62c80697d9e8c4a5f5b57832e3930313732836c4";
    sha256 = "1aj7iilhvm34y0a898fj5rz7m0b20qazsk3rlsp6lnipkadbixzs";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."rackunit-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-doc" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-doc.zip";
    sha1 = "affcc5e081c9fe571731995cb1cf4c203607afc1";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."racket-index" self."rackunit-gui" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-fancy-runner" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-fancy-runner";
  src = fetchgit {
    name = "rackunit-fancy-runner";
    url = "git://github.com/c2d7fa/rackunit-fancy-runner.git";
    rev = "c367fa93ed8a2daad4aa12cc9e947661d169dab6";
    sha256 = "0mjah7fyg3ahbmmdxrnsmq8njrw3r17d2k22b29dnbza92bayjj6";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-grade" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-grade";
  src = fetchgit {
    name = "rackunit-grade";
    url = "git://github.com/ifigueroap/racket-rackunit-grade.git";
    rev = "92526d7ced3b4cf7b5323752f20d8f36752e69b6";
    sha256 = "1yh3xz8j01i0chlxaqqirpcrh6ynlbknhfz1w7j7df8hjyqqkdmp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."doc-coverage" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-gui" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-gui";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-gui.zip";
    sha1 = "aa9d22c9cb7679de7fdb230c882f2d6c951f29ee";
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."class-iop-lib" self."data-lib" self."gui-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-lib" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-lib.zip";
    sha1 = "a65e88cfc204452b27a0b5708fe8ce0081b1da6e";
  };
  racketThinBuildInputs = [ self."base" self."testing-util-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-macrotypes-lib" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-macrotypes-lib";
  src = self.lib.extractPath {
    path = "rackunit-macrotypes-lib";
    src = fetchgit {
    name = "rackunit-macrotypes-lib";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-plugin-lib" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-plugin-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-plugin-lib.zip";
    sha1 = "efe0937b0474f0b59df7deac7ec977550d9457be";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-gui" self."gui-lib" self."drracket-plugin-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-spec" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-spec";
  src = fetchgit {
    name = "rackunit-spec";
    url = "git://github.com/lexi-lambda/rackunit-spec.git";
    rev = "96f9f48b2f4b004fafc67a3d26805983274568c4";
    sha256 = "1nzkyc82w45xgzdcvlvhsp5qh6r1gsggjd3wf3c53l2dhpkwdqfb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."rackunit-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-test" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-test.zip";
    sha1 = "86ef020ecbe656f8386b0908c609fe1dd16f12aa";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-typed" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-typed";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/rackunit-typed.zip";
    sha1 = "6f0da0871b92e22816d5b504e69c805fc2badf51";
  };
  racketThinBuildInputs = [ self."racket-index" self."rackunit-gui" self."rackunit-lib" self."typed-racket-lib" self."base" self."testing-util-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racl" = self.lib.mkRacketDerivation rec {
  pname = "racl";
  src = fetchgit {
    name = "racl";
    url = "git://github.com/tonyg/racl.git";
    rev = "a54859d0e39e61a4b69e46454ad67299d1967c4f";
    sha256 = "022aq5747md0z0ak5lw7m5syrnaiplf07snq2jv66545z3sbp1x0";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."dynext-lib" self."sandbox-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raco-bug" = self.lib.mkRacketDerivation rec {
  pname = "raco-bug";
  src = fetchgit {
    name = "raco-bug";
    url = "git://github.com/samth/raco-bug.git";
    rev = "21d5b6aa30e8efa33bf7110482dea48541399edb";
    sha256 = "0k3dhls7910ynzr27llx8xzn3xkbbf1pviqkqbfxk7dx9zi9qfy9";
  };
  racketThinBuildInputs = [ self."base" self."drracket" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raco-find-collection" = self.lib.mkRacketDerivation rec {
  pname = "raco-find-collection";
  src = fetchgit {
    name = "raco-find-collection";
    url = "git://github.com/takikawa/raco-find-collection.git";
    rev = "00f0d3dbad025fdb98d23b9ee1a78731f460d541";
    sha256 = "07ybiv87lh4y050wpfxz7jk31wklmjzf8ical1fxclwr3sk7kaws";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raco-macro-step" = self.lib.mkRacketDerivation rec {
  pname = "raco-macro-step";
  src = fetchgit {
    name = "raco-macro-step";
    url = "git://github.com/samth/raco-macro-step.git";
    rev = "efbc4ba9ebfda38624050e9cfa0452da823decf0";
    sha256 = "02pgax64qd0hl1f7q4bpr6kjy4qzsirrbin1rzl4phjshs1ar540";
  };
  racketThinBuildInputs = [ self."macro-debugger" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racquel" = self.lib.mkRacketDerivation rec {
  pname = "racquel";
  src = fetchgit {
    name = "racquel";
    url = "git://github.com/brown131/racquel.git";
    rev = "ed58ac5dfd993a5fbea88107c37dac68af7eafc3";
    sha256 = "03q0gbpjc6ysj1cdx2nwj2w47zyidjaf4mvj554cwdmssv2h874f";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racr" = self.lib.mkRacketDerivation rec {
  pname = "racr";
  src = fetchgit {
    name = "racr";
    url = "git://github.com/eeide/racr.git";
    rev = "bee5a520ec663aa58673367a453c5d2a97e8d79c";
    sha256 = "0x23sz889rpn5cvy23pqd254q9si5l2m4vnj6l9i0mhvy236cq1n";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ragg" = self.lib.mkRacketDerivation rec {
  pname = "ragg";
  src = fetchgit {
    name = "ragg";
    url = "git://github.com/jbclements/ragg.git";
    rev = "fe71542609bd707d4fd6d842d74c164ae2b2adff";
    sha256 = "1f8k5lws86crhhmn8893vd8ypgg6v706kwzldrv075yfykx4k0jp";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."rackunit-lib" self."python-tokenizer" self."at-exp-lib" self."parser-tools-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ralist" = self.lib.mkRacketDerivation rec {
  pname = "ralist";
  src = fetchgit {
    name = "ralist";
    url = "git://github.com/dvanhorn/ralist.git";
    rev = "8f830a01463c547d2588671e76202cfe566a3fb1";
    sha256 = "0qi7qc4nj2ayy4hnwdrnq2jg2b2xw7a3xjd6jb0wm9lh5lbx32ck";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-doc" self."scribble-lib" self."racket-doc" self."rackunit-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ranked-programming" = self.lib.mkRacketDerivation rec {
  pname = "ranked-programming";
  src = fetchgit {
    name = "ranked-programming";
    url = "git://github.com/tjitze/ranked-programming.git";
    rev = "5503146a8ac9779d949905b778f0d9fd6d8c0d1a";
    sha256 = "00dl8wrp28lq4m0njyy2429x0qf7hvbca1vz597a9bdppahpg4qr";
  };
  racketThinBuildInputs = [ self."sandbox-lib" self."scribble-lib" self."srfi-lite-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rapider" = self.lib.mkRacketDerivation rec {
  pname = "rapider";
  src = self.lib.extractPath {
    path = "rapider";
    src = fetchgit {
    name = "rapider";
    url = "git://github.com/nuty/rapider.git";
    rev = "f167aa91522788e70affd49e8f350cd055dba3c4";
    sha256 = "0y0lpyg47dpyqgss4349rdryyv5ms6haq2024crc4gl3vvvwym1g";
  };
  };
  racketThinBuildInputs = [ self."rapider-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rapider-lib" = self.lib.mkRacketDerivation rec {
  pname = "rapider-lib";
  src = self.lib.extractPath {
    path = "rapider-lib";
    src = fetchgit {
    name = "rapider-lib";
    url = "git://github.com/nuty/rapider.git";
    rev = "f167aa91522788e70affd49e8f350cd055dba3c4";
    sha256 = "0y0lpyg47dpyqgss4349rdryyv5ms6haq2024crc4gl3vvvwym1g";
  };
  };
  racketThinBuildInputs = [ self."base" self."sxml" self."gregor" self."html-parsing" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rascas" = self.lib.mkRacketDerivation rec {
  pname = "rascas";
  src = fetchgit {
    name = "rascas";
    url = "git://github.com/Metaxal/rascas.git";
    rev = "b86da6c036dd32ee3c3548a34da5a7c323fd9c85";
    sha256 = "0wraa3gh56prz1vcdjhmgyw0vzbfbhb6mnfzm0fr97hx39jzlwwm";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."parser-tools-lib" self."rackunit-lib" self."srfi-lite-lib" self."plot-gui-lib" self."plot-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."data-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rash" = self.lib.mkRacketDerivation rec {
  pname = "rash";
  src = self.lib.extractPath {
    path = "rash";
    src = fetchgit {
    name = "rash";
    url = "git://github.com/willghatch/racket-rash.git";
    rev = "2b33e444472cf777da3017c23a6538245a93d2d6";
    sha256 = "0pjfnbag08fqdf7nd8k6c35dhp2jjmi0a69vg8a4vdvd7cb0v04x";
  };
  };
  racketThinBuildInputs = [ self."base" self."basedir" self."shell-pipeline" self."linea" self."udelim" self."scribble-lib" self."scribble-doc" self."racket-doc" self."rackunit-lib" self."readline-lib" self."make" self."csv-reading" self."text-table" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ratchet" = self.lib.mkRacketDerivation rec {
  pname = "ratchet";
  src = fetchgit {
    name = "ratchet";
    url = "git://github.com/thoughtstem/ratchet.git";
    rev = "6dcd99e9ad43e37feeae41838282ce3b94945ca1";
    sha256 = "1z4kah7y52n6az08hgdlrkxz177q7vn86znxz1dqmhxywmvdff6c";
  };
  racketThinBuildInputs = [ self."lang-file" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ratel" = self.lib.mkRacketDerivation rec {
  pname = "ratel";
  src = fetchgit {
    name = "ratel";
    url = "git://github.com/198d/ratel.git";
    rev = "c28e0d56e9f1babad8293ab50c1f30cb3fd4df67";
    sha256 = "0rifc07milr5jc5h0d8n8m110zqc5bbvyhmysa7vnl08z2p2ps9h";
  };
  racketThinBuildInputs = [ self."base" self."threading" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raw-string" = self.lib.mkRacketDerivation rec {
  pname = "raw-string";
  src = fetchgit {
    name = "raw-string";
    url = "git://github.com/cmpitg/racket-raw-string.git";
    rev = "b2745daf6da26c58b0138ab3ec0c20c1133e0ab6";
    sha256 = "06hlnq4pmcjqyb8mnh06d8y7clxl2z07hl0z42ff24a6x1ggg4sw";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rchess" = self.lib.mkRacketDerivation rec {
  pname = "rchess";
  src = fetchgit {
    name = "rchess";
    url = "git://github.com/srfoster/rchess.git";
    rev = "77bcee50f661b638d9f05bc74149f75b21b03fed";
    sha256 = "1g5llrjhg4688by58fbrx5gw9vnj0rqvhc6b2za19qpjjkkcqw3x";
  };
  racketThinBuildInputs = [ self."base" self."chess" self."brag" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reactor" = self.lib.mkRacketDerivation rec {
  pname = "reactor";
  src = fetchgit {
    name = "reactor";
    url = "git://github.com/florence/reactor.git";
    rev = "c4687bd43fafcd09802042648900d4737b04f923";
    sha256 = "0cgdyy85yb911hxw6anlqj7cd3m3qwshbcja8x18fhp8a3fra1ni";
  };
  racketThinBuildInputs = [ self."seq-no-order" self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."rackunit" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "readline" = self.lib.mkRacketDerivation rec {
  pname = "readline";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/readline.zip";
    sha1 = "d706446c50795b093ec3c431ea488f5e87d86581";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."readline-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "readline-doc" = self.lib.mkRacketDerivation rec {
  pname = "readline-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/readline-doc.zip";
    sha1 = "8f12d8776d14edf6c62c172fbe578103ab24d7ad";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."readline-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "readline-gpl" = self.lib.mkRacketDerivation rec {
  pname = "readline-gpl";
  src = fetchgit {
    name = "readline-gpl";
    url = "git://github.com/racket/readline-gpl.git";
    rev = "c885a4b49a2ac1b59a56d108a7ed0341b71bfd86";
    sha256 = "0w6lx4fmwh40zzdz9z0nrbx6lvf8xkdkrvq9xwa6gwfa0x80y6jj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "readline-lib" = self.lib.mkRacketDerivation rec {
  pname = "readline-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/readline-lib.zip";
    sha1 = "d1c2091f2f06e1908ae2a4217241e0692eb14dac";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "realm" = self.lib.mkRacketDerivation rec {
  pname = "realm";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/realm.zip";
    sha1 = "ee5e4cfa97c2a73a1e026dd06db494f617e896b6";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rebellion" = self.lib.mkRacketDerivation rec {
  pname = "rebellion";
  src = fetchgit {
    name = "rebellion";
    url = "git://github.com/jackfirth/rebellion.git";
    rev = "86626f31a738c53dff7321e046e0f6364976cd10";
    sha256 = "0wn86lhryrw4lyfcf9ghg9ryz844k4dggj38q4xjq0a5w8f8r9zm";
  };
  racketThinBuildInputs = [ self."base" self."reprovide-lang" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "recaptcha" = self.lib.mkRacketDerivation rec {
  pname = "recaptcha";
  src = fetchgit {
    name = "recaptcha";
    url = "git://github.com/LiberalArtist/recaptcha.git";
    rev = "3064e84da6e816fb04949aa7fe12fd914296eb21";
    sha256 = "1z8ripgvmf2c8chnvaaxm3mqyq2dq0m81vyl94i6a5hm7nrxgj1m";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."scribble-lib" self."racket-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reconstruct-template" = self.lib.mkRacketDerivation rec {
  pname = "reconstruct-template";
  src = fetchgit {
    name = "reconstruct-template";
    url = "git://github.com/AlexKnauth/reconstruct-template.git";
    rev = "e3502153aeb64cbcf5809c7e89178eca54c76e34";
    sha256 = "1xhr6iy9vs70cwx62651h9rq4g43fsld8wa05qrkra34jrhjpy0c";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex" = self.lib.mkRacketDerivation rec {
  pname = "redex";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex.zip";
    sha1 = "79be2c63071cf6134e325afc8e6cc7c22ed0491e";
  };
  racketThinBuildInputs = [ self."redex-doc" self."redex-examples" self."redex-lib" self."redex-gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-aam-tutorial" = self.lib.mkRacketDerivation rec {
  pname = "redex-aam-tutorial";
  src = fetchgit {
    name = "redex-aam-tutorial";
    url = "git://github.com/dvanhorn/redex-aam-tutorial.git";
    rev = "1f3b799ee01f1d444d625be26ed7cf9d21ad6e30";
    sha256 = "1dxlnizcw7aqk525wqdy7jjq2sg3j61k7m2zp3pmblca2j4p3di7";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."scheme-lib" self."scribble-lib" self."redex-gui-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-abbrevs" = self.lib.mkRacketDerivation rec {
  pname = "redex-abbrevs";
  src = self.lib.extractPath {
    path = "redex-abbrevs";
    src = fetchgit {
    name = "redex-abbrevs";
    url = "git://github.com/bennn/redex-abbrevs.git";
    rev = "3205f90c07e5614ad90cea59eb59b7bc883167df";
    sha256 = "1varsx6q0b53rnszp27l2q1n2llpnqi1c59nzzfbvn2r2h651j0a";
  };
  };
  racketThinBuildInputs = [ self."redex-abbrevs-lib" self."redex-abbrevs-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-abbrevs-doc" = self.lib.mkRacketDerivation rec {
  pname = "redex-abbrevs-doc";
  src = self.lib.extractPath {
    path = "redex-abbrevs-doc";
    src = fetchgit {
    name = "redex-abbrevs-doc";
    url = "git://github.com/bennn/redex-abbrevs.git";
    rev = "3205f90c07e5614ad90cea59eb59b7bc883167df";
    sha256 = "1varsx6q0b53rnszp27l2q1n2llpnqi1c59nzzfbvn2r2h651j0a";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."rackunit-doc" self."redex-doc" self."redex-lib" self."redex-abbrevs-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-abbrevs-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-abbrevs-lib";
  src = self.lib.extractPath {
    path = "redex-abbrevs-lib";
    src = fetchgit {
    name = "redex-abbrevs-lib";
    url = "git://github.com/bennn/redex-abbrevs.git";
    rev = "3205f90c07e5614ad90cea59eb59b7bc883167df";
    sha256 = "1varsx6q0b53rnszp27l2q1n2llpnqi1c59nzzfbvn2r2h651j0a";
  };
  };
  racketThinBuildInputs = [ self."redex-lib" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-benchmark" = self.lib.mkRacketDerivation rec {
  pname = "redex-benchmark";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-benchmark.zip";
    sha1 = "fa3048e9116254ff99b6bfaa93a96502b08bf149";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."rackunit-lib" self."redex-lib" self."redex-examples" self."math-lib" self."plot-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-chk" = self.lib.mkRacketDerivation rec {
  pname = "redex-chk";
  src = fetchgit {
    name = "redex-chk";
    url = "git://github.com/pnwamk/redex-chk";
    rev = "b66f415966434e689842cc3cc60f8a48836d881b";
    sha256 = "1jxjg32sw1s65kn1yqs91pxyhwda4a0fwyb12i4p8fkblw505vsn";
  };
  racketThinBuildInputs = [ self."redex-lib" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-doc" = self.lib.mkRacketDerivation rec {
  pname = "redex-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-doc.zip";
    sha1 = "e3cbeb05a647d30de8acf995317eeb6642917ab6";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."draw-doc" self."gui-doc" self."htdp-doc" self."pict-doc" self."slideshow-doc" self."at-exp-lib" self."data-doc" self."data-enumerate-lib" self."scribble-lib" self."gui-lib" self."htdp-lib" self."pict-lib" self."redex-gui-lib" self."redex-benchmark" self."rackunit-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-examples" = self.lib.mkRacketDerivation rec {
  pname = "redex-examples";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-examples.zip";
    sha1 = "621b158348fc9002448a5686a044155b8f0fbeb7";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."rackunit-lib" self."redex-gui-lib" self."slideshow-lib" self."math-lib" self."plot-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-gui-lib.zip";
    sha1 = "37b98594d295fde54cbbac0974552dbd5a02e55a";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."draw-lib" self."gui-lib" self."data-lib" self."profile-lib" self."redex-lib" self."redex-pict-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-lib.zip";
    sha1 = "a719b967e9e1efbe118857bc313889762b8dbe89";
  };
  racketThinBuildInputs = [ self."data-enumerate-lib" self."scheme-lib" self."base" self."data-lib" self."math-lib" self."tex-table" self."profile-lib" self."typed-racket-lib" self."testing-util-lib" self."2d-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-parameter" = self.lib.mkRacketDerivation rec {
  pname = "redex-parameter";
  src = fetchgit {
    name = "redex-parameter";
    url = "git://github.com/camoy/redex-parameter.git";
    rev = "9e0421cca00632f8696512271741951d90446f47";
    sha256 = "11x1igkh5qgibhfy9h744mjyp9hnkzl6p81dqmp10l1g3b2kgnjh";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."redex-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-pict-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-pict-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-pict-lib.zip";
    sha1 = "1afeb8566437704ab989d5b73dbfa8c8722ae814";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."draw-lib" self."data-lib" self."profile-lib" self."redex-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-test" = self.lib.mkRacketDerivation rec {
  pname = "redex-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/redex-test.zip";
    sha1 = "c53817a444099846e4dae9e68c9b4636ce4cb7b8";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."compatibility-lib" self."drracket" self."gui-lib" self."pict-lib" self."redex-gui-lib" self."redex-examples" self."data-enumerate-lib" self."data-lib" self."racket-index" self."scheme-lib" self."slideshow-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redis" = self.lib.mkRacketDerivation rec {
  pname = "redis";
  src = fetchgit {
    name = "redis";
    url = "git://github.com/stchang/redis.git";
    rev = "ec69a3ea1c6b5eda35502361bc88d204c38b1120";
    sha256 = "1mgv35kns9wsdpq9jcmkqp04ya8b6r7p4cqqdld8y0zldif084q2";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redis-doc" = self.lib.mkRacketDerivation rec {
  pname = "redis-doc";
  src = self.lib.extractPath {
    path = "redis-doc";
    src = fetchgit {
    name = "redis-doc";
    url = "git://github.com/Bogdanp/racket-redis.git";
    rev = "d8126931b981999caf48185daf940a8a1c56f23d";
    sha256 = "1xfbp0jrjmwc32zyl0ayy0aab8p9g9kpmmsv4bybbrnjigdkm4q6";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."redis-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redis-lib" = self.lib.mkRacketDerivation rec {
  pname = "redis-lib";
  src = self.lib.extractPath {
    path = "redis-lib";
    src = fetchgit {
    name = "redis-lib";
    url = "git://github.com/Bogdanp/racket-redis.git";
    rev = "d8126931b981999caf48185daf940a8a1c56f23d";
    sha256 = "1xfbp0jrjmwc32zyl0ayy0aab8p9g9kpmmsv4bybbrnjigdkm4q6";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redis-rkt" = self.lib.mkRacketDerivation rec {
  pname = "redis-rkt";
  src = self.lib.extractPath {
    path = "redis";
    src = fetchgit {
    name = "redis-rkt";
    url = "git://github.com/Bogdanp/racket-redis.git";
    rev = "d8126931b981999caf48185daf940a8a1c56f23d";
    sha256 = "1xfbp0jrjmwc32zyl0ayy0aab8p9g9kpmmsv4bybbrnjigdkm4q6";
  };
  };
  racketThinBuildInputs = [ self."base" self."redis-doc" self."redis-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redis-test" = self.lib.mkRacketDerivation rec {
  pname = "redis-test";
  src = self.lib.extractPath {
    path = "redis-test";
    src = fetchgit {
    name = "redis-test";
    url = "git://github.com/Bogdanp/racket-redis.git";
    rev = "d8126931b981999caf48185daf940a8a1c56f23d";
    sha256 = "1xfbp0jrjmwc32zyl0ayy0aab8p9g9kpmmsv4bybbrnjigdkm4q6";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."redis-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reed-solomon" = self.lib.mkRacketDerivation rec {
  pname = "reed-solomon";
  src = fetchgit {
    name = "reed-solomon";
    url = "git://github.com/simmone/racket-reed-solomon.git";
    rev = "0ae962b14a0fcd3daff5ea90ccf9a3b6411700a7";
    sha256 = "06m7rn55i70n6kd2b5bgm09ji393m10wzmn3c07q82mvps9ccaac";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "refined-acl2" = self.lib.mkRacketDerivation rec {
  pname = "refined-acl2";
  src = fetchgit {
    name = "refined-acl2";
    url = "git://github.com/carl-eastlund/refined-acl2.git";
    rev = "2e344ad7bcbc5b5a758296a8158dcf9a7f3880bd";
    sha256 = "0d34c281l2rbcns8l4fg53di787dzxqqn11fgp9i14nih0rzh3gx";
  };
  racketThinBuildInputs = [ self."mischief" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "regex-machine" = self.lib.mkRacketDerivation rec {
  pname = "regex-machine";
  src = fetchgit {
    name = "regex-machine";
    url = "git://github.com/jackfirth/regex-machine.git";
    rev = "25754a4dc2aae351e2fe5db1b98101abb9ce088e";
    sha256 = "1b8p7j1h4an30y7m58aqaxdxwshbb2znld538qs7p7w2yabdpmha";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."pict-lib" self."reprovide-lang" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "regraph" = self.lib.mkRacketDerivation rec {
  pname = "regraph";
  src = fetchgit {
    name = "regraph";
    url = "git://github.com/herbie-fp/regraph.git";
    rev = "2289be64752032bcac530d5cf5a2c3dc4276c978";
    sha256 = "1p9hikbrdxwkj9gs3kzcpgggxqn70h9jdss59gwji421k4agc4s8";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reloadable" = self.lib.mkRacketDerivation rec {
  pname = "reloadable";
  src = fetchgit {
    name = "reloadable";
    url = "git://github.com/tonyg/racket-reloadable.git";
    rev = "cae2a141955bc2e0d068153f2cd07f88e6a6e9ef";
    sha256 = "0fzdp3nyl4786ykl264iyc5wfaw83sa44lavjf4rkwj8rghn68a2";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remap" = self.lib.mkRacketDerivation rec {
  pname = "remap";
  src = fetchgit {
    name = "remap";
    url = "https://gitlab.com/hashimmm/remap.git";
    rev = "d51fb2169b79e6bf5cfdd175af08239d3362445c";
    sha256 = "0pf83498ai63lnadr6a50vghmj6bhlf20amx2ri72zq4n2ajczgz";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."rackunit-typed" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remember" = self.lib.mkRacketDerivation rec {
  pname = "remember";
  src = fetchgit {
    name = "remember";
    url = "git://github.com/jsmaniac/remember.git";
    rev = "6d497291dcc0d90e5437300aef70d462f7865c91";
    sha256 = "1vzmdmpym78b9rzl2mbvbjijnygv80gzb86wjdiks2l2vf46lml1";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."compatibility-lib" self."scribble-lib" self."typed-racket-lib" self."phc-toolkit" self."hyper-literate" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."scribble-enhanced" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remix" = self.lib.mkRacketDerivation rec {
  pname = "remix";
  src = fetchgit {
    name = "remix";
    url = "git://github.com/jeapostrophe/remix.git";
    rev = "982529019d12252b5f6ab49c17a1a8283ccfb9df";
    sha256 = "0zvv1wv78091884xjbj2ysv9cvdksgj0mqmy5243nbz769nsxckd";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."rackunit-lib" self."datalog" self."scribble-doc" self."rackunit-lib" self."base" self."racket-doc" self."scribble-lib" self."typed-racket-lib" self."unstable-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remote-shell" = self.lib.mkRacketDerivation rec {
  pname = "remote-shell";
  src = self.lib.extractPath {
    path = "remote-shell";
    src = fetchgit {
    name = "remote-shell";
    url = "git://github.com/racket/remote-shell.git";
    rev = "ab126cbb064560e5ad6919db73354f7366b9085b";
    sha256 = "0sjfiz0xkqn5sggczc3spkii6xr1pnxb51nyh3d6c8crj8saiqii";
  };
  };
  racketThinBuildInputs = [ self."remote-shell-lib" self."remote-shell-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remote-shell-doc" = self.lib.mkRacketDerivation rec {
  pname = "remote-shell-doc";
  src = self.lib.extractPath {
    path = "remote-shell-doc";
    src = fetchgit {
    name = "remote-shell-doc";
    url = "git://github.com/racket/remote-shell.git";
    rev = "ab126cbb064560e5ad6919db73354f7366b9085b";
    sha256 = "0sjfiz0xkqn5sggczc3spkii6xr1pnxb51nyh3d6c8crj8saiqii";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."remote-shell-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remote-shell-lib" = self.lib.mkRacketDerivation rec {
  pname = "remote-shell-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/remote-shell-lib.zip";
    sha1 = "bba0aaa8404d16552bcf07fa8184ff7b1e27e8d9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "repeated-application" = self.lib.mkRacketDerivation rec {
  pname = "repeated-application";
  src = fetchgit {
    name = "repeated-application";
    url = "git://github.com/v-nys/repeated-application.git";
    rev = "6a5ef2192f38f01de98deb03532b4b3d83b09ed3";
    sha256 = "0cdx2zv32fpixgzjxkmi5hq1fry7hi8qcb0jj989vd3h5zf29cn9";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."sugar" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "repltest" = self.lib.mkRacketDerivation rec {
  pname = "repltest";
  src = fetchgit {
    name = "repltest";
    url = "git://github.com/jsmaniac/repltest.git";
    rev = "23d62fec561abf14a587d07ad6c896e8d012ed1d";
    sha256 = "0v2gsl2p3bj4s4hl651wqis1dlhw2n6y89xivxb2a6x4r1m8ji8h";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."afl" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reprovide-lang" = self.lib.mkRacketDerivation rec {
  pname = "reprovide-lang";
  src = self.lib.extractPath {
    path = "reprovide-lang";
    src = fetchgit {
    name = "reprovide-lang";
    url = "git://github.com/AlexKnauth/reprovide-lang.git";
    rev = "49c4c867964ddff42c5c61fe8a7e814851ed8a0c";
    sha256 = "1k69fr49jcmm99r2x5q564kzfzbalpljrzsjw3x4qc7q0nvcx9ap";
  };
  };
  racketThinBuildInputs = [ self."base" self."reprovide-lang-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reprovide-lang-lib" = self.lib.mkRacketDerivation rec {
  pname = "reprovide-lang-lib";
  src = self.lib.extractPath {
    path = "reprovide-lang-lib";
    src = fetchgit {
    name = "reprovide-lang-lib";
    url = "git://github.com/AlexKnauth/reprovide-lang.git";
    rev = "49c4c867964ddff42c5c61fe8a7e814851ed8a0c";
    sha256 = "1k69fr49jcmm99r2x5q564kzfzbalpljrzsjw3x4qc7q0nvcx9ap";
  };
  };
  racketThinBuildInputs = [ self."base" self."lang-file-lib" self."syntax-macro-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "request" = self.lib.mkRacketDerivation rec {
  pname = "request";
  src = fetchgit {
    name = "request";
    url = "git://github.com/jackfirth/racket-request.git";
    rev = "1665f5ff84d6713a6531666caaa736b2b395b6a4";
    sha256 = "03fh7baag3wpx1dxxcl55kym13zxpha3qn337k22c743dynrk1h3";
  };
  racketThinBuildInputs = [ self."base" self."fancy-app" self."rackunit-lib" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."net-doc" self."rackunit-lib" self."rackunit-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "require-typed-check" = self.lib.mkRacketDerivation rec {
  pname = "require-typed-check";
  src = fetchgit {
    name = "require-typed-check";
    url = "git://github.com/bennn/require-typed-check.git";
    rev = "7e8777a8576a74084c577b82dafaa759fe5ddfa8";
    sha256 = "1d4dw1djkkzq4facnvyf2f9kbqk2cldpzb3mjzsmdy9jq5wzqvb5";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "response-ext" = self.lib.mkRacketDerivation rec {
  pname = "response-ext";
  src = fetchgit {
    name = "response-ext";
    url = "git://github.com/Junker/response-ext.git";
    rev = "50c95a7799602079b6a77d5576832a8d91a4bbd5";
    sha256 = "0a4226yzmxqjm5fl1fcxnwb5mpv8spnzxrn4ld98sq202zdr1z10";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "restore" = self.lib.mkRacketDerivation rec {
  pname = "restore";
  src = fetchgit {
    name = "restore";
    url = "git://github.com/jeapostrophe/restore.git";
    rev = "c38049acd1bde962453977d2469cf2ae8b99acb7";
    sha256 = "0w93j42rq3dh66686qnv74vhmb8vw9s9yhs4chmb531mk0qmh51c";
  };
  racketThinBuildInputs = [ self."base" self."unstable-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "retry" = self.lib.mkRacketDerivation rec {
  pname = "retry";
  src = fetchgit {
    name = "retry";
    url = "git://github.com/jackfirth/racket-retry.git";
    rev = "2a6ba58ab5f14707305e75063c3ee4519fc6dc7d";
    sha256 = "1hqk1zp41yzqnk3djkx3b51ax9mnh5dpbq8admqyzvcwd5v6x358";
  };
  racketThinBuildInputs = [ self."compose-app" self."fancy-app" self."gregor-lib" self."reprovide-lang" self."base" self."mock" self."at-exp-lib" self."gregor-doc" self."scribble-text-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" self."mock-rackunit" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "review" = self.lib.mkRacketDerivation rec {
  pname = "review";
  src = fetchgit {
    name = "review";
    url = "git://github.com/Bogdanp/racket-review.git";
    rev = "7c6ab882a9a4cb3bb141ef1f02086c4af5b16c6d";
    sha256 = "0s09yvzy378gzqj51n9vanwsip5z3cbb5g6w6r1al437s21cg6sr";
  };
  racketThinBuildInputs = [ self."base" self."base" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rex" = self.lib.mkRacketDerivation rec {
  pname = "rex";
  src = fetchgit {
    name = "rex";
    url = "git://github.com/alehed/rex.git";
    rev = "e3b41f706b4b72ea5f168b0f2a2600d77ee07ea0";
    sha256 = "11hr1hwhfbkyn16hwfz534p03qp7yabmxw66g07dc48mglgrvbrn";
  };
  racketThinBuildInputs = [ self."base" self."br-parser-tools-lib" self."brag" self."data-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rfc3339-old" = self.lib.mkRacketDerivation rec {
  pname = "rfc3339-old";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/rfc3339-old.zip";
    sha1 = "4f52cf57d9905cbf8683f1aa25a23ba8d4ecc004";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rfc6455" = self.lib.mkRacketDerivation rec {
  pname = "rfc6455";
  src = fetchgit {
    name = "rfc6455";
    url = "git://github.com/tonyg/racket-rfc6455.git";
    rev = "abdf0099c6930986a4ea9f352b9fb34ba73afea5";
    sha256 = "0wd6gvmnx1zwq73k7pc6lgx6ql8imqi6adfv87bi6dqs3wiyz53m";
  };
  racketThinBuildInputs = [ self."base" self."net-lib" self."rackunit-lib" self."web-server-lib" self."scribble-lib" self."net-doc" self."racket-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ricoeur-kernel" = self.lib.mkRacketDerivation rec {
  pname = "ricoeur-kernel";
  src = fetchgit {
    name = "ricoeur-kernel";
    url = "https://bitbucket.org/digitalricoeur/ricoeur-kernel.git";
    rev = "1192906c24f8714cc179131ca921887ccdd5a2aa";
    sha256 = "0hsrvr97vz5di9yw7l5a9kffb34w57fdz2ca4kwrpknk00g10c1r";
  };
  racketThinBuildInputs = [ self."base" self."adjutor" self."reprovide-lang" self."gregor" self."functional-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ricoeur-tei-utils" = self.lib.mkRacketDerivation rec {
  pname = "ricoeur-tei-utils";
  src = fetchgit {
    name = "ricoeur-tei-utils";
    url = "https://bitbucket.org/digitalricoeur/tei-utils.git";
    rev = "545c192aff9138d05bdd1aeb97d0f145508b84a8";
    sha256 = "1akdw1p9f8vdm49083l0l9wdlrzyvizr1rbcrrs76px9m5afis83";
  };
  racketThinBuildInputs = [ self."base" self."adjutor" self."ricoeur-kernel" self."functional-lib" self."roman-numeral" self."gregor-lib" self."gui-lib" self."pict-lib" self."scribble-lib" self."data-lib" self."db-lib" self."sql" self."draw-lib" self."icns" self."parser-tools-lib" self."pict-snip-lib" self."nanopass" self."reprovide-lang-lib" self."typed-racket-lib" self."typed-racket-more" self."xmllint-win32-x86_64" self."at-exp-lib" self."syntax-color-lib" self."scribble-lib" self."racket-doc" self."at-exp-lib" self."functional-doc" self."gregor-doc" self."rackunit-lib" self."_-exp" self."db-doc" self."data-doc" self."gui-doc" self."scribble-doc" self."todo-list" self."racket-index" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "riff" = self.lib.mkRacketDerivation rec {
  pname = "riff";
  src = fetchgit {
    name = "riff";
    url = "git://github.com/lehitoskin/riff.git";
    rev = "459efecc4168cf922660f95b6195935d66cb6a2b";
    sha256 = "0il8m7ap5hmavzkp2l56kjdwnns0ligzk5i675xpzk24k9vf6b9z";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rilouworld" = self.lib.mkRacketDerivation rec {
  pname = "rilouworld";
  src = fetchgit {
    name = "rilouworld";
    url = "git://github.com/euhmeuh/rilouworld.git";
    rev = "184dea6c187f4f94da6616b89ec15cc8ba6bb786";
    sha256 = "18a5dc49jwyk1lwcfcz4slbbhx1mppklvncnjf23b0d4fk1bsfka";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."draw-lib" self."anaphoric" self."web-server-lib" self."mode-lambda" self."lux" self."reprovide-lang" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ring-buffer" = self.lib.mkRacketDerivation rec {
  pname = "ring-buffer";
  src = fetchgit {
    name = "ring-buffer";
    url = "git://github.com/jeapostrophe/ring-buffer.git";
    rev = "e93665407487ca0d31e1dadebc570371044f0c27";
    sha256 = "1c0s8mvx3r4fh04h8hbs4hqzaysz3xf65jj7r5dj54ijmlamlq3i";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "riposte" = self.lib.mkRacketDerivation rec {
  pname = "riposte";
  src = fetchgit {
    name = "riposte";
    url = "git://github.com/vicampo/riposte.git";
    rev = "434d9478f52e618f6192a626a11252ee90f0c9e5";
    sha256 = "0n4mkbrr3s5m5d3a7z1wai5z2br9vhh04dxk8w8ydl93bg22f0nx";
  };
  racketThinBuildInputs = [ self."br-parser-tools-lib" self."brag-lib" self."net-cookies-lib" self."web-server-lib" self."base" self."racket-doc" self."brag-lib" self."br-parser-tools-lib" self."beautiful-racket-lib" self."http" self."net-cookies-lib" self."argo" self."dotenv" self."json-pointer" self."misc1" self."scribble-lib" self."rackunit-lib" self."web-server-lib" self."net-cookies-lib" self."beautiful-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rival" = self.lib.mkRacketDerivation rec {
  pname = "rival";
  src = fetchgit {
    name = "rival";
    url = "git://github.com/herbie-fp/rival.git";
    rev = "5ea4d93f3111ad2bb01c4cf891eae99a91a5ce27";
    sha256 = "0j8r3v4hzcvfwf0hwy0ly060rq3pwiwmm7qbyi596vg97y259njq";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."rackunit-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rmacs" = self.lib.mkRacketDerivation rec {
  pname = "rmacs";
  src = fetchgit {
    name = "rmacs";
    url = "git://github.com/tonyg/rmacs.git";
    rev = "8c99dd5dfa22f1f34707bbe957de268dc6a7a632";
    sha256 = "11608v9b5x3ah6zxvp8rxljl7zy3krj9n7nvl02h1cy073g770qz";
  };
  racketThinBuildInputs = [ self."base" self."ansi" self."syntax-color-lib" self."gui-lib" self."unix-signals" self."diff-merge" self."web-server-lib" self."profile-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rmc" = self.lib.mkRacketDerivation rec {
  pname = "rmc";
  src = fetchgit {
    name = "rmc";
    url = "git://github.com/jeapostrophe/rmc.git";
    rev = "e11425287cfecb3940f75a25a29f9b74826c2605";
    sha256 = "0jk1whndmk8cmyb7z0gz91xk5jghs2akpnhq2y19d1bl61y9n0ak";
  };
  racketThinBuildInputs = [ self."pprint" self."chk" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rml-core" = self.lib.mkRacketDerivation rec {
  pname = "rml-core";
  src = fetchgit {
    name = "rml-core";
    url = "git://github.com/johnstonskj/rml-core.git";
    rev = "aa73f78a14e5724fba95349d18d59c5125af45bd";
    sha256 = "1ys8jl8xng4l3xlpsjlr3gbxman2gdfd6x5jgns34zd0wffbfkd2";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."csv-reading" self."mcfly" self."rackunit-lib" self."racket-index" self."scribble-lib" self."racket-doc" self."math-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rml-decisiontrees" = self.lib.mkRacketDerivation rec {
  pname = "rml-decisiontrees";
  src = fetchgit {
    name = "rml-decisiontrees";
    url = "git://github.com/johnstonskj/rml-decisiontrees.git";
    rev = "180b22bfcc3a3a0134302c6e738cde3659e7be3f";
    sha256 = "0k7y3zbgl8c0jx576s5kzvkzyvn3pqwsab3wi90p4v6agkaaky10";
  };
  racketThinBuildInputs = [ self."base" self."rml-core" self."math-lib" self."sandbox-lib" self."racket-index" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rml-knn" = self.lib.mkRacketDerivation rec {
  pname = "rml-knn";
  src = fetchgit {
    name = "rml-knn";
    url = "git://github.com/johnstonskj/rml-knn.git";
    rev = "83e3755c56b1c486b9fc1663b4ef21b2254b9634";
    sha256 = "0vgmp36zia561f90whf3bhpgb3882jjvvv5fxfcl35ahg88jhz1d";
  };
  racketThinBuildInputs = [ self."base" self."rml-core" self."math-lib" self."rackunit-lib" self."racket-index" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rml-neural" = self.lib.mkRacketDerivation rec {
  pname = "rml-neural";
  src = fetchgit {
    name = "rml-neural";
    url = "git://github.com/johnstonskj/rml-neural.git";
    rev = "5e3c95ab118007e16ac25627229674894e8c5302";
    sha256 = "1fgix0j1b37ibgxf06477jga08pqp3hvyyyd9vlg4izjlw01hg1d";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."plot-gui-lib" self."plot-lib" self."rackunit-lib" self."scribble-lib" self."scribble-math" self."racket-doc" self."racket-index" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rockstar" = self.lib.mkRacketDerivation rec {
  pname = "rockstar";
  src = self.lib.extractPath {
    path = "rockstar";
    src = fetchgit {
    name = "rockstar";
    url = "git://github.com/whichxjy/rockstar-rkt.git";
    rev = "47723774e7ec6995eedd8fba27856b58ab056f71";
    sha256 = "1mhygdqpz4wmzxj7rn3c34sd6qhbj1vg4kkpcfrgi48d2ij0bk26";
  };
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."brag-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rokit-racket" = self.lib.mkRacketDerivation rec {
  pname = "rokit-racket";
  src = self.lib.extractPath {
    path = "rokit-racket";
    src = fetchgit {
    name = "rokit-racket";
    url = "git://github.com/thoughtstem/rokit-racket.git";
    rev = "4b5362ff1d2204384270a0ffa786023a17886e0d";
    sha256 = "1wb5fj9b5ip6mq4aqisyfykagr7gg0myf101z7jscdq3sgxm9clk";
  };
  };
  racketThinBuildInputs = [ self."racket-to" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "roman-numeral" = self.lib.mkRacketDerivation rec {
  pname = "roman-numeral";
  src = fetchgit {
    name = "roman-numeral";
    url = "git://github.com/LiberalArtist/roman-numeral.git";
    rev = "eac42b23bd0349e3141573e33984244ebec9c41c";
    sha256 = "0k8pk4aaavqk610i4jclp51k5k6170cif8rpspmrh7ca2idz2vj9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "roomba" = self.lib.mkRacketDerivation rec {
  pname = "roomba";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/roomba.zip";
    sha1 = "7d3968beb6d16886038e6b3875144d074990ef33";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."scribble-lib" self."scribble-lib" self."racket-doc" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rosetta" = self.lib.mkRacketDerivation rec {
  pname = "rosetta";
  src = fetchgit {
    name = "rosetta";
    url = "git://github.com/aptmcl/rosetta.git";
    rev = "38aeafd730f93edaec7474106e84dae6d8bc1261";
    sha256 = "00zpd0gg3rk8kri1lahli8jaq6a6lcallwagvv4qh3aqgd4f601v";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rosette" = self.lib.mkRacketDerivation rec {
  pname = "rosette";
  src = fetchgit {
    name = "rosette";
    url = "git://github.com/emina/rosette.git";
    rev = "6a165a8229d124ad57e6eee314732f2e972d5ca2";
    sha256 = "02gmg36wplk4zj14c80xgb24278lwsprz6xra0nj52sw5dbl5nag";
  };
  racketThinBuildInputs = [ self."custom-load" self."sandbox-lib" self."scribble-lib" self."r6rs-lib" self."rfc6455" self."net-lib" self."web-server-lib" self."rackunit-lib" self."slideshow-lib" self."gui-lib" self."base" self."rackunit-doc" self."draw-lib" self."errortrace-lib" self."pict-lib" self."pict-doc" self."scribble-lib" self."racket-doc" self."gui-doc" self."errortrace-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rosette-extras" = self.lib.mkRacketDerivation rec {
  pname = "rosette-extras";
  src = fetchgit {
    name = "rosette-extras";
    url = "git://github.com/lenary/rosette-extras.git";
    rev = "66f45e9cddd8ac3e2c9b182e38a71dd49c8ef089";
    sha256 = "0ar4qygf73rd3fifjsr1d1mirrakppymsv7aqsa45w40h6rnwqih";
  };
  racketThinBuildInputs = [ self."base" self."rosette" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "routy" = self.lib.mkRacketDerivation rec {
  pname = "routy";
  src = fetchgit {
    name = "routy";
    url = "git://github.com/Junker/routy.git";
    rev = "2c48b4649ee102c8f175cae59bf5eeb6d6a041c9";
    sha256 = "1l9sllyccs6rzv4vqybaa95605i3raycws7pl3b9p9baqh8rwynl";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."rackunit-lib" self."racket-route-match" self."response-ext" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rpn" = self.lib.mkRacketDerivation rec {
  pname = "rpn";
  src = fetchgit {
    name = "rpn";
    url = "git://github.com/jackfirth/rpn.git";
    rev = "ecb962109a3f3d056d6ebf66ed4542081f6526e1";
    sha256 = "1c25n3gs4bznwr4aidwrz5dif40kf5pvn9cviww63mvlizsyl41d";
  };
  racketThinBuildInputs = [ self."base" self."rebellion" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rs" = self.lib.mkRacketDerivation rec {
  pname = "rs";
  src = fetchgit {
    name = "rs";
    url = "git://github.com/mcdejonge/rs.git";
    rev = "8a82b5e7644f19e0d6bae6658ffb8587497e5548";
    sha256 = "1idr0i1w9ca4jrxcy4y317i7prbkwayj2l7gvrhw7q8ya9csgr4c";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."rtmidi" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rsa" = self.lib.mkRacketDerivation rec {
  pname = "rsa";
  src = fetchgit {
    name = "rsa";
    url = "git://github.com/mgbowe1/racket-rsa.git";
    rev = "0498189663e984d849ef4f2109cfd32058b247e0";
    sha256 = "0cd9d2nfhaz6c56kykl0d2lksf2qzvhsa87zqmacqlkf5y4w85q9";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rsc3" = self.lib.mkRacketDerivation rec {
  pname = "rsc3";
  src = fetchgit {
    name = "rsc3";
    url = "git://github.com/quakehead/rsc3.git";
    rev = "a25985dab29ad951893cd7afa6d86a9371315871";
    sha256 = "0lyj710x7777liljyqyvcac7n95vwan35qpdh9806g8hwmiwq5h1";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."r6rs-lib" self."srfi-lib" self."srfi-lite-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rsound" = self.lib.mkRacketDerivation rec {
  pname = "rsound";
  src = fetchgit {
    name = "rsound";
    url = "git://github.com/jbclements/RSound.git";
    rev = "77e62cd517009a5f192012d0d7274c3270a44a94";
    sha256 = "0pq6vf62b8n09raph4mnmsbc9gjn2c1scgi6qax4qr8s07v44w2z";
  };
  racketThinBuildInputs = [ self."portaudio" self."base" self."data-lib" self."gui-lib" self."htdp-lib" self."math-lib" self."plot-lib" self."plot-gui-lib" self."rackunit-lib" self."typed-racket-lib" self."drracket-plugin-lib" self."memoize" self."pict-lib" self."wxme-lib" self."snip-lib" self."scribble-lib" self."racket-doc" self."wxme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rsvg" = self.lib.mkRacketDerivation rec {
  pname = "rsvg";
  src = fetchgit {
    name = "rsvg";
    url = "git://github.com/takikawa/racket-rsvg.git";
    rev = "c326fe15679086b471fa529befa6b4241883271f";
    sha256 = "1yfl4rvmdikla2sygvg2jqjj51c8g8bcy66bls03jqhss17zd013";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."pict-doc" self."scribble-lib" self."rackunit-lib" self."scribble-lib" self."pict-lib" self."draw-doc" self."racket-doc" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rtmidi" = self.lib.mkRacketDerivation rec {
  pname = "rtmidi";
  src = fetchgit {
    name = "rtmidi";
    url = "git://github.com/jbclements/rtmidi.git";
    rev = "999afcca0987f831047499a291c96dca077ed3fe";
    sha256 = "1v0bdasblcw755kpxvh6iwgc5ar9pyc8933ldgjcwyr759zwa398";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rtnl" = self.lib.mkRacketDerivation rec {
  pname = "rtnl";
  src = fetchgit {
    name = "rtnl";
    url = "git://github.com/mordae/racket-rtnl.git";
    rev = "53cf9eb3d1927cd4357ebdf785ffb58cacff6c3e";
    sha256 = "183x992v809imi7k24kz3b1a5mgn65l91b35vxsq366rgx6mfpn0";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ruckus" = self.lib.mkRacketDerivation rec {
  pname = "ruckus";
  src = fetchgit {
    name = "ruckus";
    url = "git://github.com/cbiffle/ruckus.git";
    rev = "62cd4a00837783a88a007c2d5979909a4e86ca0f";
    sha256 = "1zrxznyalfmhykmj1203pn56i804101c7jgwia0nbzddwwmii7na";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."math-lib" self."opengl" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ruinit" = self.lib.mkRacketDerivation rec {
  pname = "ruinit";
  src = fetchgit {
    name = "ruinit";
    url = "git://github.com/LLazarek/ruinit.git";
    rev = "9afaab5d419557060bc9d360bdc042252406d5ff";
    sha256 = "1a2yf5pvap1jgd37h0s5lybkwi9pddfjw89c022f507rpb31s49d";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "russian" = self.lib.mkRacketDerivation rec {
  pname = "russian";
  src = fetchgit {
    name = "russian";
    url = "git://github.com/Kalimehtar/russian.git";
    rev = "f2c93e3a680b4fcfe147099b8fa99bb7062d0674";
    sha256 = "10nhnphjcql40k7m0ipnxdi1fwkkd4hsq7sm2klzm1fbylf0wri3";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lite-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rwind" = self.lib.mkRacketDerivation rec {
  pname = "rwind";
  src = fetchgit {
    name = "rwind";
    url = "git://github.com/Metaxal/rwind.git";
    rev = "865e872cef7edf2a317ae063784d1c971404b06c";
    sha256 = "1y418jlnjllx311706fj61y2f73hiiv3lv4vyb6nj9w9fwdmldan";
  };
  racketThinBuildInputs = [ self."x11" self."base" self."rackunit-lib" self."slideshow-lib" self."readline-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rws-html-template" = self.lib.mkRacketDerivation rec {
  pname = "rws-html-template";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/rws-html-template.zip";
    sha1 = "18af61049ea3adf14472753ccc6ba0602563ff61";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."web-server-lib" self."web-server-doc" self."mcfly" self."html-template" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "s-lib" = self.lib.mkRacketDerivation rec {
  pname = "s-lib";
  src = fetchgit {
    name = "s-lib";
    url = "git://github.com/caisah/s-lib.git";
    rev = "de6ae621d8ffd670fede37f51212c8cb5a84bcf3";
    sha256 = "09n0s2g708pdz11wajiz8l5fkcp16r00wrb5nr37k80zfgf579d7";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "s3-sync" = self.lib.mkRacketDerivation rec {
  pname = "s3-sync";
  src = fetchgit {
    name = "s3-sync";
    url = "git://github.com/mflatt/s3-sync.git";
    rev = "d2f9bd298df3f4368817ff6a18c6f23304e1ffa4";
    sha256 = "15zmis9rs42n29701nd7b6afk87cy8rcksk7wx9533ksx3dv0cg7";
  };
  racketThinBuildInputs = [ self."aws" self."http" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sandbox-lib" = self.lib.mkRacketDerivation rec {
  pname = "sandbox-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sandbox-lib.zip";
    sha1 = "5b47cda8fd72796ac1b423acac3cdfb8f7ddb43c";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."errortrace-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl" = self.lib.mkRacketDerivation rec {
  pname = "sasl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sasl.zip";
    sha1 = "913dabd64c533519e111e44d9b11153f4330ae50";
  };
  racketThinBuildInputs = [ self."sasl-lib" self."sasl-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-doc" = self.lib.mkRacketDerivation rec {
  pname = "sasl-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sasl-doc.zip";
    sha1 = "4436c24789ee460ff64f9a36f3071cb41cfe7914";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."sasl-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-lib" = self.lib.mkRacketDerivation rec {
  pname = "sasl-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sasl-lib.zip";
    sha1 = "3ad9d1386daa715a62ed8a0bca52d384341d9dfa";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-test" = self.lib.mkRacketDerivation rec {
  pname = "sasl-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sasl-test.zip";
    sha1 = "9f3f09be28f9adb9844f2562ab7f68950814eafc";
  };
  racketThinBuildInputs = [ self."base" self."sasl-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sass" = self.lib.mkRacketDerivation rec {
  pname = "sass";
  src = self.lib.extractPath {
    path = "sass";
    src = fetchgit {
    name = "sass";
    url = "git://github.com/Bogdanp/racket-sass.git";
    rev = "377f35b70cde9e239b1e08ad25e432eb7ab58bb7";
    sha256 = "0zql8nbq2p4463p87zm6dpbwpg1gkjy9k08fjs3mywpk9xdb0nic";
  };
  };
  racketThinBuildInputs = [ self."base" self."libsass-i386-win32" self."libsass-x86_64-linux" self."libsass-x86_64-macosx" self."libsass-x86_64-win32" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."libsass-i386-win32" self."libsass-x86_64-linux" self."libsass-x86_64-macosx" self."libsass-x86_64-win32" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sau-cptr-405" = self.lib.mkRacketDerivation rec {
  pname = "sau-cptr-405";
  src = fetchurl {
    url = "http://computing.southern.edu/rordonez/class/CPTR-405/sau-cptr-405.zip";
    sha1 = "a7fb41d932b9dafe499c0972bdb8eb9692e8ff91";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."htdp-lib" self."net-lib" self."pconvert-lib" self."sandbox-lib" self."rackunit-lib" self."web-server-lib" self."plait" self."gui-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scgi" = self.lib.mkRacketDerivation rec {
  pname = "scgi";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/scgi.zip";
    sha1 = "07cc9ba2713cb0d947931cdf1011a84d5ccfb4da";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "schema" = self.lib.mkRacketDerivation rec {
  pname = "schema";
  src = fetchgit {
    name = "schema";
    url = "git://github.com/wargrey/schema.git";
    rev = "c21a9feab6da0bb81b7035ef890507a7bbfd3e8a";
    sha256 = "0pay340gw2pslba5r9wv0g1rfa7794zrx1q3vb4kn21bdsaadsqq";
  };
  racketThinBuildInputs = [ self."base" self."w3s" self."db-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scheme-lib" = self.lib.mkRacketDerivation rec {
  pname = "scheme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scheme-lib.zip";
    sha1 = "11565cf336f1cfe17bffe687c4834585817bb08a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "schemeunit" = self.lib.mkRacketDerivation rec {
  pname = "schemeunit";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/schemeunit.zip";
    sha1 = "7dbf033685de83ad3a94741507c33abb9ce9780a";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-gui" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scope-operations" = self.lib.mkRacketDerivation rec {
  pname = "scope-operations";
  src = fetchgit {
    name = "scope-operations";
    url = "git://github.com/jsmaniac/scope-operations.git";
    rev = "475928d46e32efb7a506443efd6ce0b99990f665";
    sha256 = "0l1z5mzajkzwlxvprlgcaxzbmswyp9y7qc9i938vnm1qyf7ypadl";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scrapyard" = self.lib.mkRacketDerivation rec {
  pname = "scrapyard";
  src = fetchgit {
    name = "scrapyard";
    url = "git://github.com/lassik/racket-scrapyard.git";
    rev = "23b49c3562f3b8fea01886a219230fe37e2abf2d";
    sha256 = "0qwq6gm1kxp11jxsb1p4lglgl70b9zaf4r3zr11mikrg52y5r0fr";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."sxml" self."txexpr" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scratch" = self.lib.mkRacketDerivation rec {
  pname = "scratch";
  src = fetchgit {
    name = "scratch";
    url = "git://github.com/LeifAndersen/racket-scratch.git";
    rev = "92ec687d248f7ce587589305611367512d2a0506";
    sha256 = "00yy0ivml5vh26816pdr198qjxqkpl5rb2lvfw36h62628ys553y";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."reprovide-lang" self."at-exp-lib" self."gui-lib" self."pict-lib" self."plot-gui-lib" self."draw-lib" self."data-lib" self."profile-lib" self."wxme-lib" self."sandbox-lib" self."syntax-color-lib" self."zo-lib" self."with-cache" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scratchy" = self.lib.mkRacketDerivation rec {
  pname = "scratchy";
  src = fetchgit {
    name = "scratchy";
    url = "git://github.com/mflatt/scratchy.git";
    rev = "aef8883759fc962828bf977811697fccf06ef8b0";
    sha256 = "0b274p7yhw3h0449sv7wkx82qrfpkbffyz3skfajw17nrv9lnx2c";
  };
  racketThinBuildInputs = [ self."algol60" self."base" self."draw-lib" self."gui-lib" self."parser-tools-lib" self."slideshow-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble" = self.lib.mkRacketDerivation rec {
  pname = "scribble";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble.zip";
    sha1 = "e3c514f8874d5d5cbfb306adfa8d012fa2706a79";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-abbrevs" = self.lib.mkRacketDerivation rec {
  pname = "scribble-abbrevs";
  src = fetchgit {
    name = "scribble-abbrevs";
    url = "git://github.com/bennn/scribble-abbrevs.git";
    rev = "ecd6328cf21cd869c867587212fc0d8fdbf38f85";
    sha256 = "10j3sak3bdgyklqwkf7n1qlqzzp2335zmi26aizmlwb40hbk8dwv";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."reprovide-lang" self."pict-lib" self."draw-lib" self."scribble-lib" self."scribble-doc" self."racket-doc" self."rackunit-abbrevs" self."rackunit-lib" self."rackunit-abbrevs" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-code-examples" = self.lib.mkRacketDerivation rec {
  pname = "scribble-code-examples";
  src = self.lib.extractPath {
    path = "scribble-code-examples";
    src = fetchgit {
    name = "scribble-code-examples";
    url = "git://github.com/AlexKnauth/scribble-code-examples.git";
    rev = "18166292d8d491881cf5ac98352c23bd5ebec312";
    sha256 = "0drhqlp903fgvsdjz13zxbas7320yqz8mxdxd76z0zsghsng8yd8";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-code-examples-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-code-examples-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-code-examples-lib";
  src = self.lib.extractPath {
    path = "scribble-code-examples-lib";
    src = fetchgit {
    name = "scribble-code-examples-lib";
    url = "git://github.com/AlexKnauth/scribble-code-examples.git";
    rev = "18166292d8d491881cf5ac98352c23bd5ebec312";
    sha256 = "0drhqlp903fgvsdjz13zxbas7320yqz8mxdxd76z0zsghsng8yd8";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."sandbox-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-coq" = self.lib.mkRacketDerivation rec {
  pname = "scribble-coq";
  src = fetchgit {
    name = "scribble-coq";
    url = "git://github.com/wilbowma/scribble-coq.git";
    rev = "894ec4c1b1e97f3d50608bfba1c1d4361c7d3d5f";
    sha256 = "052v2fajndxyh3g4n6c7xf6m2viyaqf6wgzjkrgmwan8mvwh8mdn";
  };
  racketThinBuildInputs = [ self."threading-lib" self."scribble-lib" self."scribble-minted" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-doc" = self.lib.mkRacketDerivation rec {
  pname = "scribble-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble-doc.zip";
    sha1 = "a1648265ebd9c09428b6f8dd5a93c00add34bbf0";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."racket-index" self."scheme-lib" self."at-exp-lib" self."base" self."compatibility-lib" self."draw-lib" self."pict-lib" self."sandbox-lib" self."slideshow-lib" self."scribble-lib" self."scribble-text-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-enhanced" = self.lib.mkRacketDerivation rec {
  pname = "scribble-enhanced";
  src = fetchgit {
    name = "scribble-enhanced";
    url = "git://github.com/jsmaniac/scribble-enhanced.git";
    rev = "a9e385f71759ad6421107e577f2a0782c16cef07";
    sha256 = "091qq76zy0p05k199535b2jdk9prszsd79f974dw4x74fggnr999";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."scheme-lib" self."compatibility-lib" self."slideshow-lib" self."typed-racket-lib" self."reprovide-lang" self."mutable-match-lambda" self."scribble-lib" self."racket-doc" self."at-exp-lib" self."typed-racket-more" self."typed-racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-frog-helper" = self.lib.mkRacketDerivation rec {
  pname = "scribble-frog-helper";
  src = fetchgit {
    name = "scribble-frog-helper";
    url = "git://github.com/yanyingwang/scribble-frog-helper.git";
    rev = "e2a887017e3241eddae4e54bf1352e2fb20b6b76";
    sha256 = "0ym7m11hyz539prk290kizx9gasw8g7yrsyi3msz5rvpbig0m41x";
  };
  racketThinBuildInputs = [ self."base" self."gregor" self."timable" self."frog" self."at-exp-lib" self."scribble-lib" self."racket-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-html-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-html-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble-html-lib.zip";
    sha1 = "7f001bedf8ab0eaea4c8d40fc56b544bfa6644d4";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."at-exp-lib" self."scribble-text-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble-lib.zip";
    sha1 = "78f52a9877c2fbe72425461dbf4841e112449587";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."scribble-text-lib" self."scribble-html-lib" self."planet-lib" self."net-lib" self."at-exp-lib" self."draw-lib" self."syntax-color-lib" self."sandbox-lib" self."typed-racket-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-math" = self.lib.mkRacketDerivation rec {
  pname = "scribble-math";
  src = fetchgit {
    name = "scribble-math";
    url = "git://github.com/jsmaniac/scribble-math.git";
    rev = "1793123c881915c1731620f99aa8e4e281abb59b";
    sha256 = "16q9ch68dylqvliwsswkcnmdjhxjs3jq6839j517lqy9cp28zfga";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."at-exp-lib" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-minted" = self.lib.mkRacketDerivation rec {
  pname = "scribble-minted";
  src = fetchgit {
    name = "scribble-minted";
    url = "git://github.com/wilbowma/scribble-minted.git";
    rev = "d1721e699877d2100ab0fbdffb4ab80bd9286bb4";
    sha256 = "1m138w5afkzjr2w2qmi1h41wiyd2b4qjbkr056acp7rjx8w4612w";
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."scribble-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-test" = self.lib.mkRacketDerivation rec {
  pname = "scribble-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble-test.zip";
    sha1 = "6fba3962454c32e16365ab3d1990248c5481d4fb";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."eli-tester" self."rackunit-lib" self."sandbox-lib" self."scribble-doc" self."scribble-lib" self."scribble-text-lib" self."racket-index" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-text-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-text-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/scribble-text-lib.zip";
    sha1 = "16682c83df3285e4abd5f65ecd45b5a5be82a443";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scriblogify" = self.lib.mkRacketDerivation rec {
  pname = "scriblogify";
  src = fetchgit {
    name = "scriblogify";
    url = "git://github.com/rmculpepper/scriblogify";
    rev = "7771d00ce6101bd5d415b54134eb79c42b92f1ef";
    sha256 = "1bpjdxmc4ihhndahk3q5vapa13w8fs5mdi9vynx0qxfzw5g3l5b9";
  };
  racketThinBuildInputs = [ self."base" self."sxml" self."webapi" self."scribble-lib" self."compatibility-lib" self."web-server-lib" self."html-parsing" self."html-writing" self."racket-doc" self."scribble-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "script-plugin" = self.lib.mkRacketDerivation rec {
  pname = "script-plugin";
  src = fetchgit {
    name = "script-plugin";
    url = "git://github.com/Metaxal/script-plugin.git";
    rev = "c5ab635bae65c6fcaac5221bdce9f6efc9e6c674";
    sha256 = "1mz7xrqhh377k5f3l5yylb378gnkc1j449l7p9mlrwzn73m94ggj";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."html-lib" self."net-lib" self."planet-lib" self."slideshow-lib" self."srfi-lite-lib" self."gui-doc" self."racket-doc" self."racket-index" self."scribble-lib" self."web-server-lib" self."planet-doc" self."draw-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scripty" = self.lib.mkRacketDerivation rec {
  pname = "scripty";
  src = self.lib.extractPath {
    path = "scripty";
    src = fetchgit {
    name = "scripty";
    url = "git://github.com/lexi-lambda/scripty.git";
    rev = "09a0e2fd24dfcd5942177d4a328821534ee60ded";
    sha256 = "0ib233dr7vlm6vwkxzb24vpgj5f9my894dd2ja0ry5ykl75cvzia";
  };
  };
  racketThinBuildInputs = [ self."scripty-doc" self."scripty-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scripty-doc" = self.lib.mkRacketDerivation rec {
  pname = "scripty-doc";
  src = self.lib.extractPath {
    path = "scripty-doc";
    src = fetchgit {
    name = "scripty-doc";
    url = "git://github.com/lexi-lambda/scripty.git";
    rev = "09a0e2fd24dfcd5942177d4a328821534ee60ded";
    sha256 = "0ib233dr7vlm6vwkxzb24vpgj5f9my894dd2ja0ry5ykl75cvzia";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."scripty-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scripty-lib" = self.lib.mkRacketDerivation rec {
  pname = "scripty-lib";
  src = self.lib.extractPath {
    path = "scripty-lib";
    src = fetchgit {
    name = "scripty-lib";
    url = "git://github.com/lexi-lambda/scripty.git";
    rev = "09a0e2fd24dfcd5942177d4a328821534ee60ded";
    sha256 = "0ib233dr7vlm6vwkxzb24vpgj5f9my894dd2ja0ry5ykl75cvzia";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scrypt" = self.lib.mkRacketDerivation rec {
  pname = "scrypt";
  src = fetchgit {
    name = "scrypt";
    url = "git://github.com/tonyg/racket-scrypt.git";
    rev = "0a37d1cdca43e08c086f0e2e312c7916cb790edb";
    sha256 = "0xm6apzgilf4g664rw5bzicl30gf534xvf4pvl1g27jnww9lcq27";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."dynext-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sdl" = self.lib.mkRacketDerivation rec {
  pname = "sdl";
  src = self.lib.extractPath {
    path = "sdl";
    src = fetchgit {
    name = "sdl";
    url = "git://github.com/cosmez/racket-sdl.git";
    rev = "8b31e76b77b24afe76683d4d5630c771a0329683";
    sha256 = "067v0dhf7w8n2rixcpbndc4wkq36mfs3yng4lprl41nyq70kyx5w";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sdl2" = self.lib.mkRacketDerivation rec {
  pname = "sdl2";
  src = fetchgit {
    name = "sdl2";
    url = "git://github.com/lockie/racket-sdl2.git";
    rev = "ef380f86bfb41ad50b12caa278a501854647e84a";
    sha256 = "12c2gsy97q8svs0fh53b8dcm8w3vcvwk3jjb0d94b42y8ww1g7xy";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sdraw" = self.lib.mkRacketDerivation rec {
  pname = "sdraw";
  src = fetchgit {
    name = "sdraw";
    url = "git://github.com/jackrosenthal/sdraw-racket.git";
    rev = "b885937074fa2c8ac0db4df2f84f11ea3e52ddcf";
    sha256 = "1wpc7fzxaiz0zdj87zylq6nyrmj2yzi1rr8hs779zgl918dhpafk";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "search-upward" = self.lib.mkRacketDerivation rec {
  pname = "search-upward";
  src = fetchgit {
    name = "search-upward";
    url = "git://github.com/zyrolasting/search-upward.git";
    rev = "02016d0ca3bdd76d69c9d376ae84936a63c5ca6e";
    sha256 = "17h5w6y4g1xnmx4xq3y2fn1f6v2wa4iyf7dn4d7rlvrfdm2s9ddy";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "secd" = self.lib.mkRacketDerivation rec {
  pname = "secd";
  src = fetchgit {
    name = "secd";
    url = "git://github.com/GPRicci/secd.git";
    rev = "cebf4c32d4c48c6d964449788c0e708524872120";
    sha256 = "1kypfg3sq8zy3nyv43s6gqd0c3ix739hijw5frpg15cs8lfg8n56";
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."brag" self."data-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "semilit" = self.lib.mkRacketDerivation rec {
  pname = "semilit";
  src = fetchgit {
    name = "semilit";
    url = "git://github.com/samth/semilit.git";
    rev = "51a4c9d2bc1d2307a732c488745b7d2cdda22f98";
    sha256 = "1fas98gwfav7janmaz2svz1ld8g607z8pbvvvqv4ky1ch8s7ngsf";
  };
  racketThinBuildInputs = [ self."base" self."datalog" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "semver" = self.lib.mkRacketDerivation rec {
  pname = "semver";
  src = fetchgit {
    name = "semver";
    url = "git://github.com/lexi-lambda/racket-semver.git";
    rev = "20f87e1c2d84b687b82dff3e58187df13f231d73";
    sha256 = "16p688kkwlyiaz9c9nriajw05jr0ck8qhvlwdfhvspmzl3lnf2vh";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."alexis-util" self."racket-doc" self."scribble-lib" self."typed-racket-doc" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "send-exp" = self.lib.mkRacketDerivation rec {
  pname = "send-exp";
  src = fetchgit {
    name = "send-exp";
    url = "git://github.com/tonyg/racket-send-exp.git";
    rev = "fcbb060fb9a0d8efc6810f6d77accf11093f6c8e";
    sha256 = "04v25vw69xbzlv42zlypy19x6wq0p0rd5jycgyfhkrfc2j4nil5m";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sentry" = self.lib.mkRacketDerivation rec {
  pname = "sentry";
  src = self.lib.extractPath {
    path = "sentry";
    src = fetchgit {
    name = "sentry";
    url = "git://github.com/Bogdanp/racket-sentry.git";
    rev = "9794b2da9c4f3ca8c8094d6bc78d5ca8bf9b133b";
    sha256 = "0fzkqkzxk1pcf6v151nm9i4wfw4bwl9m9h8ifxwvs80lsa6x6rfs";
  };
  };
  racketThinBuildInputs = [ self."sentry-doc" self."sentry-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sentry-doc" = self.lib.mkRacketDerivation rec {
  pname = "sentry-doc";
  src = self.lib.extractPath {
    path = "sentry-doc";
    src = fetchgit {
    name = "sentry-doc";
    url = "git://github.com/Bogdanp/racket-sentry.git";
    rev = "9794b2da9c4f3ca8c8094d6bc78d5ca8bf9b133b";
    sha256 = "0fzkqkzxk1pcf6v151nm9i4wfw4bwl9m9h8ifxwvs80lsa6x6rfs";
  };
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."sentry-lib" self."scribble-lib" self."web-server-lib" self."gregor-doc" self."racket-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sentry-lib" = self.lib.mkRacketDerivation rec {
  pname = "sentry-lib";
  src = self.lib.extractPath {
    path = "sentry-lib";
    src = fetchgit {
    name = "sentry-lib";
    url = "git://github.com/Bogdanp/racket-sentry.git";
    rev = "9794b2da9c4f3ca8c8094d6bc78d5ca8bf9b133b";
    sha256 = "0fzkqkzxk1pcf6v151nm9i4wfw4bwl9m9h8ifxwvs80lsa6x6rfs";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."gregor-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sentry-test" = self.lib.mkRacketDerivation rec {
  pname = "sentry-test";
  src = self.lib.extractPath {
    path = "sentry-test";
    src = fetchgit {
    name = "sentry-test";
    url = "git://github.com/Bogdanp/racket-sentry.git";
    rev = "9794b2da9c4f3ca8c8094d6bc78d5ca8bf9b133b";
    sha256 = "0fzkqkzxk1pcf6v151nm9i4wfw4bwl9m9h8ifxwvs80lsa6x6rfs";
  };
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."rackunit-lib" self."sentry-lib" self."threading-lib" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "seq-no-order" = self.lib.mkRacketDerivation rec {
  pname = "seq-no-order";
  src = fetchgit {
    name = "seq-no-order";
    url = "git://github.com/AlexKnauth/seq-no-order.git";
    rev = "dd9bc6956a2431f986d0b02aabcf61f5c91dc82f";
    sha256 = "1242qsh9z55ydks51p23q775xspxzdhxnkk6lgrhqgd34h4xff0g";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "serial" = self.lib.mkRacketDerivation rec {
  pname = "serial";
  src = fetchgit {
    name = "serial";
    url = "git://github.com/BartAdv/racket-serial.git";
    rev = "47cb5ed979cdcd9481001aeb559e82c0d96bb42a";
    sha256 = "1l7zhvbh6rivz1kbvclkwx9mjrm37w2yid9by3mjyhf4b4wh3q4p";
  };
  racketThinBuildInputs = [ self."base" self."termios" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "serialize-cstruct-lib" = self.lib.mkRacketDerivation rec {
  pname = "serialize-cstruct-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/serialize-cstruct-lib.zip";
    sha1 = "da9eecfbd449dc9c7a2c02d9bd8042da9d6dbb80";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "serialize-syntax-introducer" = self.lib.mkRacketDerivation rec {
  pname = "serialize-syntax-introducer";
  src = fetchgit {
    name = "serialize-syntax-introducer";
    url = "git://github.com/macrotypefunctors/serialize-syntax-introducer.git";
    rev = "5944d9f32df50b608c3493a7fd6a510afabf8fd3";
    sha256 = "01kzkp19i437biz3kb5xf3kcsqjh77npzng3cnsbnixlx0ljlhi1";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "set" = self.lib.mkRacketDerivation rec {
  pname = "set";
  src = fetchgit {
    name = "set";
    url = "git://github.com/samth/set.rkt.git";
    rev = "655e2567cefe9684b0425a0ec601a97d1faf7d0e";
    sha256 = "0jp8na3bsb7511sx70y9l4cr6sy5a2pbvid9bc3ls0f45zdlkl14";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "set-exp" = self.lib.mkRacketDerivation rec {
  pname = "set-exp";
  src = fetchgit {
    name = "set-exp";
    url = "git://github.com/jackfirth/set-exp.git";
    rev = "19c898f13278efee5399de7307fc95d0f53ee82d";
    sha256 = "14l96fdzj7031950xw559nx0f4n84z76bwwgsgz7zlcg4jx1c26b";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."doc-coverage" self."cover" self."doc-coverage" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "set-extras" = self.lib.mkRacketDerivation rec {
  pname = "set-extras";
  src = self.lib.extractPath {
    path = "set-extras";
    src = fetchgit {
    name = "set-extras";
    url = "git://github.com/philnguyen/set-extras.git";
    rev = "7feeb7a3a6b05c2e9ce39a0ff31eae25e150119d";
    sha256 = "0h9vnigjgvhp48cqzb46ar3a6yg83zgyg2h1i3kfklfdrvx3v8j0";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sexp-diff" = self.lib.mkRacketDerivation rec {
  pname = "sexp-diff";
  src = fetchgit {
    name = "sexp-diff";
    url = "git://github.com/stamourv/sexp-diff.git";
    rev = "5b5034c7e6b930002870877e8e1eb1e6d69ae0b4";
    sha256 = "0wjdz3kb2f5hbb1ha8x2ksgc3ccb5pfwh75m6fpnkjy9vdv1dq8a";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sfont" = self.lib.mkRacketDerivation rec {
  pname = "sfont";
  src = fetchgit {
    name = "sfont";
    url = "git://github.com/danielecapo/sfont.git";
    rev = "18b842c24164b4cda04cd042e2a9ce608445a14d";
    sha256 = "19hscm196dv0aqgmcxxqgfr1p583a1qa3zsq62rd6fk9177jzvq6";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."slideshow-lib" self."pict-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sgl" = self.lib.mkRacketDerivation rec {
  pname = "sgl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/sgl.zip";
    sha1 = "e6a0f01534e7aa2b2369e280a952ed74a145051f";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."gui-lib" self."draw-doc" self."gui-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sha" = self.lib.mkRacketDerivation rec {
  pname = "sha";
  src = fetchgit {
    name = "sha";
    url = "git://github.com/greghendershott/sha.git";
    rev = "6d61cdfad6e4cc0c439e09fc9cf10d691043c1c7";
    sha256 = "0p8v2217z0f2wgg1d2bnjf7xgk6qhqfg8kn4r4z3d4fq7xfiybc1";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "shell-completion" = self.lib.mkRacketDerivation rec {
  pname = "shell-completion";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/shell-completion.zip";
    sha1 = "0408fc542e0b1e26d103b66ecb876711af1e74eb";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "shell-pipeline" = self.lib.mkRacketDerivation rec {
  pname = "shell-pipeline";
  src = self.lib.extractPath {
    path = "shell-pipeline";
    src = fetchgit {
    name = "shell-pipeline";
    url = "git://github.com/willghatch/racket-rash.git";
    rev = "2b33e444472cf777da3017c23a6538245a93d2d6";
    sha256 = "0pjfnbag08fqdf7nd8k6c35dhp2jjmi0a69vg8a4vdvd7cb0v04x";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "shootout" = self.lib.mkRacketDerivation rec {
  pname = "shootout";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/shootout.zip";
    sha1 = "8d4454844112861f4baeb72d8ed6b22e53c28448";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sicp" = self.lib.mkRacketDerivation rec {
  pname = "sicp";
  src = fetchgit {
    name = "sicp";
    url = "git://github.com/sicp-lang/sicp.git";
    rev = "bcd43c7d19bbab8745138917c2b16ddf4472d794";
    sha256 = "1fy0srkclzddfc7v3a45az209vxzwryh2a35ldmw4lzb8m9pk9vn";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."r5rs-lib" self."rackunit-lib" self."snip-lib" self."draw-doc" self."gui-doc" self."r5rs-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "signature" = self.lib.mkRacketDerivation rec {
  pname = "signature";
  src = fetchgit {
    name = "signature";
    url = "git://github.com/thinkmoore/signature.git";
    rev = "c8be60858474259d27f94b23214f7397d9653eb1";
    sha256 = "1wk5d61npy1j2iyf636ny069mmd02nc9n28g05qba6x75dzcjv33";
  };
  racketThinBuildInputs = [ self."kw-utils" self."racklog" self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-barcode" = self.lib.mkRacketDerivation rec {
  pname = "simple-barcode";
  src = fetchgit {
    name = "simple-barcode";
    url = "git://github.com/simmone/racket-simple-barcode.git";
    rev = "1ef356f4082755e333ad9c6b0a04774f94b23dbd";
    sha256 = "0gckldwl3xxy1gq7rkpqsbwgls84l5gp0vdr56pkalikldj2hfxh";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."draw-lib" self."simple-svg" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-http" = self.lib.mkRacketDerivation rec {
  pname = "simple-http";
  src = fetchgit {
    name = "simple-http";
    url = "git://github.com/DarrenN/simple-http.git";
    rev = "e7c96ed5f325c08f9e5455318cc939cb5a0af1c9";
    sha256 = "1nr2plizl0419flhn5j2jab64z1qk0fnjd68k89x9ggm0cqz22ff";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."html-parsing" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-oauth2" = self.lib.mkRacketDerivation rec {
  pname = "simple-oauth2";
  src = fetchgit {
    name = "simple-oauth2";
    url = "git://github.com/johnstonskj/simple-oauth2.git";
    rev = "5393058265f20669ab3c683e4aa660f80f0e0d30";
    sha256 = "0r4x8pmc08ax41jijblwfv9ml0npnv8nafphx1zdskh1csnakmbl";
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."dali" self."net-jwt" self."threading" self."web-server-lib" self."rackunit-lib" self."rackunit-spec" self."scribble-lib" self."racket-doc" self."racket-index" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-qr" = self.lib.mkRacketDerivation rec {
  pname = "simple-qr";
  src = fetchgit {
    name = "simple-qr";
    url = "git://github.com/simmone/racket-simple-qr.git";
    rev = "5f3c1bfac51f897e8a9bcd1f25e9b40b5eb4cdf3";
    sha256 = "1ikm30pnq3m9mjxc55b1wgaky0zvkjbxh5aza3448i3v1b3hxhwp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."draw-lib" self."draw-doc" self."racket-doc" self."scribble-lib" self."reed-solomon" self."simple-svg" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-svg" = self.lib.mkRacketDerivation rec {
  pname = "simple-svg";
  src = fetchgit {
    name = "simple-svg";
    url = "git://github.com/simmone/racket-simple-svg.git";
    rev = "daf6658b9786ec6ee6eb3622216cd694eae46e2c";
    sha256 = "078kzrd2l0q7pjiy543w2sn5dzw39rqlcaw0rkklywkzil71cgwj";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-xlsx" = self.lib.mkRacketDerivation rec {
  pname = "simple-xlsx";
  src = fetchgit {
    name = "simple-xlsx";
    url = "git://github.com/simmone/racket-simple-xlsx.git";
    rev = "977c944406e6e8b9e70b702defd722a867f4fcb3";
    sha256 = "14j53rb0qrrpp71aydbz1asifca6aw3cgqj7ax4gr214sn509pq4";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simply-scheme" = self.lib.mkRacketDerivation rec {
  pname = "simply-scheme";
  src = fetchgit {
    name = "simply-scheme";
    url = "git://github.com/jbclements/simply-scheme.git";
    rev = "8b8ba2b50d8688c0db30a772c5eac7bb2f6400a7";
    sha256 = "0zm1m28j301yf72c0iwclqqzbnjwcl4d59ladw35h2ys46p6g48f";
  };
  racketThinBuildInputs = [ self."base" self."drracket-plugin-lib" self."gui-lib" self."string-constants-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sinbad" = self.lib.mkRacketDerivation rec {
  pname = "sinbad";
  src = self.lib.extractPath {
    path = "sinbad";
    src = fetchgit {
    name = "sinbad";
    url = "git://github.com/berry-cs/sinbad-rkt.git";
    rev = "44b3e0881514bbfb7cc91780262968748b9f92eb";
    sha256 = "189c39zp12pl6vvvbfbld1c4qchrsvjzii9hfxq99nxwbsr9vda3";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-lib" self."htdp-lib" self."csv-reading" self."sxml" self."srfi-lite-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sirmail" = self.lib.mkRacketDerivation rec {
  pname = "sirmail";
  src = fetchgit {
    name = "sirmail";
    url = "git://github.com/mflatt/sirmail.git";
    rev = "8eb1abeb6809cbf84f2fac5609b9e2baf0c762c3";
    sha256 = "0p1csaih23khfab24gbzyhsqi41s4k7rdp1qrjd5pz4s4x8w07gq";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket" self."gui-lib" self."net-lib" self."parser-tools-lib" self."scheme-lib" self."syntax-color-lib" self."sandbox-lib" self."pict-lib" self."pict-snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sl2014" = self.lib.mkRacketDerivation rec {
  pname = "sl2014";
  src = fetchgit {
    name = "sl2014";
    url = "git://github.com/mfelleisen/sl2014.git";
    rev = "4ffef910ae5109eef916f3d57aaab95f02981df9";
    sha256 = "1izfcyvk6iwk42rgiwn67vndkzi3km6w8ncddiivy70k8jjd8hx5";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slack-api" = self.lib.mkRacketDerivation rec {
  pname = "slack-api";
  src = fetchgit {
    name = "slack-api";
    url = "git://github.com/octotep/racket-slack-api.git";
    rev = "af5e363e0aefbf05c4448ea82d8aef714c30ee78";
    sha256 = "11sk22gskj1izn1fyxkjnc2vjw2sl4d7hg7hd2711d0jkn7j3krv";
  };
  racketThinBuildInputs = [ self."base" self."rfc6455" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slatex" = self.lib.mkRacketDerivation rec {
  pname = "slatex";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slatex.zip";
    sha1 = "54d560fcb2a43b25c644fa6c5fedbd7237bca222";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."racket-index" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow" = self.lib.mkRacketDerivation rec {
  pname = "slideshow";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slideshow.zip";
    sha1 = "405bf8b0012ff6d28f6755b48077a25f6ddbb87e";
  };
  racketThinBuildInputs = [ self."slideshow-lib" self."slideshow-exe" self."slideshow-plugin" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-doc" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slideshow-doc.zip";
    sha1 = "a5b94aca72904e18413795aa802253745d186c0a";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."gui-lib" self."pict-lib" self."scribble-lib" self."slideshow-lib" self."at-exp-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-exe" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-exe";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slideshow-exe.zip";
    sha1 = "b14a2571ae4ef1c19ad302f0d9fbacbba5190fc6";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."gui-lib" self."pict-lib" self."slideshow-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-latex" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-latex";
  src = fetchgit {
    name = "slideshow-latex";
    url = "git://github.com/jeapostrophe/slideshow-latex.git";
    rev = "73aab49b3a14ea06afbfeb2e5ebd32f148c0196c";
    sha256 = "1mp45w7i0ajgm5iv5ayr0jyicsw4r7y4gqz3q39909gll7frgwfc";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."slideshow-lib" self."racket-doc" self."scribble-lib" self."slideshow-doc" self."planet-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-lib" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slideshow-lib.zip";
    sha1 = "ca65ca1490a88b03b1f49ded360d20b5f20f0841";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."draw-lib" self."pict-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-plugin" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-plugin";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/slideshow-plugin.zip";
    sha1 = "7b7ca907a91eb325b5b786c145b0164b7a5fd8f8";
  };
  racketThinBuildInputs = [ self."base" self."slideshow-lib" self."pict-lib" self."string-constants-lib" self."compatibility-lib" self."drracket-plugin-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-pretty" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-pretty";
  src = fetchgit {
    name = "slideshow-pretty";
    url = "git://github.com/LeifAndersen/slideshow-pretty.git";
    rev = "021378757a40163f8e84efe616eb17036eeb2a4f";
    sha256 = "1ls5awaqjrsmbcdwd8vwh22rpdgj9j017k6mbahmxk7zb7bs17dv";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."slideshow-lib" self."slideshow-latex" self."racket-doc" self."scribble-lib" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-repl" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-repl";
  src = fetchgit {
    name = "slideshow-repl";
    url = "git://github.com/mflatt/slideshow-repl.git";
    rev = "e8d3f8fb08322cd1aa9553c1c0079d7bebb3e823";
    sha256 = "0mdsglpz1j1ijifmsqkjlxcwdpnczwkrq4hxy89sfn2nxji5kr0d";
  };
  racketThinBuildInputs = [ self."errortrace-lib" self."gui-lib" self."slideshow-lib" self."base" self."pict-lib" self."pict-snip-lib" self."draw-doc" self."draw-lib" self."pict-doc" self."racket-doc" self."scribble-lib" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-text-style" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-text-style";
  src = fetchgit {
    name = "slideshow-text-style";
    url = "git://github.com/takikawa/slideshow-text-style.git";
    rev = "ffba8fe0c9f94580a1751345f1dbb2813712b1f1";
    sha256 = "11zjkgvpmlmyzchjry7w0jbpraqkldy90sy54m2vqw3rq4ihdrdc";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."slideshow-lib" self."scribble-text-lib" self."scribble-lib" self."at-exp-lib" self."pict-doc" self."slideshow-doc" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "smart-completion" = self.lib.mkRacketDerivation rec {
  pname = "smart-completion";
  src = fetchgit {
    name = "smart-completion";
    url = "git://github.com/syntacticlosure/smart-completion.git";
    rev = "53ab196bee90d578d9fd09ab9f44a165a7143684";
    sha256 = "0sfgc0bj8bgza2j15i5icgsjn9ns7464zcggfql2sk6mm5l2vj6q";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sml" = self.lib.mkRacketDerivation rec {
  pname = "sml";
  src = fetchgit {
    name = "sml";
    url = "git://github.com/LeifAndersen/racket-sml.git";
    rev = "f7a03fdf124dff96a1fe2d7eadfd260a5824b1c5";
    sha256 = "05p2v9yf8d6kyfpfm3k6v610w36blmk05dgrzqzrcdn13xv14vgs";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "smtp" = self.lib.mkRacketDerivation rec {
  pname = "smtp";
  src = fetchgit {
    name = "smtp";
    url = "git://github.com/yanyingwang/smtp.git";
    rev = "ea05853bae041938988ff7a913dab0cc4df01ebe";
    sha256 = "0yvqrw1jp8013ffjk20i4sil0vpx4j19gcdkhvkdxb19apcv2r4r";
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."at-exp-lib" self."r6rs-lib" self."uuid" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "smtp-lib" = self.lib.mkRacketDerivation rec {
  pname = "smtp-lib";
  src = fetchgit {
    name = "smtp-lib";
    url = "git://github.com/yanyingwang/smtp-lib.git";
    rev = "b0d3600adfcd12555a58ff328a63564d52233e44";
    sha256 = "18cqf0lv7pzq17alczhkg6mq62qggwx4hrsism4zpjjncvxw91wd";
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."at-exp-lib" self."r6rs-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "snack" = self.lib.mkRacketDerivation rec {
  pname = "snack";
  src = fetchurl {
    url = "https://www.cs.toronto.edu/~gfb/racket-pkgs/snack.zip";
    sha1 = "24a6c942197d85856b5d12b864724ed6200a8d11";
  };
  racketThinBuildInputs = [ self."base" self."base" self."gui-lib" self."draw-lib" self."reprovide-lang" self."string-constants-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "snappy" = self.lib.mkRacketDerivation rec {
  pname = "snappy";
  src = fetchgit {
    name = "snappy";
    url = "git://github.com/stchang/snappy.git";
    rev = "c97436037ff6600dc7df447a5aba3d59c3e7e011";
    sha256 = "0v3s9c7ijrgxwgh388qjxi98zb9sv862vlq8azqk31wkwa6w82m9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "snip" = self.lib.mkRacketDerivation rec {
  pname = "snip";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/snip.zip";
    sha1 = "26d046e4c7d0a2a130266df37c260c3b7198f741";
  };
  racketThinBuildInputs = [ self."snip-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "snip-lib" = self.lib.mkRacketDerivation rec {
  pname = "snip-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/snip-lib.zip";
    sha1 = "455d24a09bb624911232a4a1cea62ea82becb4f3";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "socketcan" = self.lib.mkRacketDerivation rec {
  pname = "socketcan";
  src = fetchgit {
    name = "socketcan";
    url = "git://github.com/abencz/racket-socketcan";
    rev = "744bf37d7a347a55d1ec72885f87d35919f68b7b";
    sha256 = "0y005rgkkbaly7z6k40pprj8icxrad5qifh77zy847sd0cg4lciv";
  };
  racketThinBuildInputs = [ self."base" self."make" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "softposit-herbie" = self.lib.mkRacketDerivation rec {
  pname = "softposit-herbie";
  src = fetchgit {
    name = "softposit-herbie";
    url = "git://github.com/herbie-fp/softposit-herbie.git";
    rev = "ce640acfdc6ebb3dac045d0c1542285a3e0c81fe";
    sha256 = "1n7shrd8340kp8ljzm4cr6g695z7i2b8snnn8y54gsgb3h3bca7j";
  };
  racketThinBuildInputs = [ self."math-lib" self."base" self."softposit-rkt" self."herbie" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "softposit-rkt" = self.lib.mkRacketDerivation rec {
  pname = "softposit-rkt";
  src = fetchgit {
    name = "softposit-rkt";
    url = "git://github.com/DavidThien/softposit-rkt.git";
    rev = "862aa557248e2489e9446c84f9676361272778f2";
    sha256 = "0xj5yfgsc5w4n7ylx5mv52fr58d94rxr4zy1b3nr30plah194303";
  };
  racketThinBuildInputs = [ self."math-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sonic-pi" = self.lib.mkRacketDerivation rec {
  pname = "sonic-pi";
  src = fetchgit {
    name = "sonic-pi";
    url = "git://github.com/jbclements/sonic-pi.git";
    rev = "de70c9169b7bb6b6764c513c6caac25f533c79dc";
    sha256 = "18grfs28akg2k8pc3xwsb77pamk9q1hwd35vz42apn9x88rcq62h";
  };
  racketThinBuildInputs = [ self."base" self."osc" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."htdp-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "soundex" = self.lib.mkRacketDerivation rec {
  pname = "soundex";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/soundex.zip";
    sha1 = "b870344d2cae67642346fa919f46aded96624703";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "source-syntax" = self.lib.mkRacketDerivation rec {
  pname = "source-syntax";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/source-syntax.zip";
    sha1 = "c498a8e0af87ba655613e99c3d7ea90ac102077b";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sparse" = self.lib.mkRacketDerivation rec {
  pname = "sparse";
  src = fetchgit {
    name = "sparse";
    url = "git://github.com/ricky-escobar/sparse.git";
    rev = "0d713dd9524c5bbba7fbebe49f44cbe9aab70275";
    sha256 = "1jp3lkvx6q6wybg13xldaj4ifdf9aplbfkframazqj24lf55zrif";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "spipe" = self.lib.mkRacketDerivation rec {
  pname = "spipe";
  src = fetchgit {
    name = "spipe";
    url = "git://github.com/BourgondAries/spipe.git";
    rev = "d6bc777a8113447fea9a3f10b5a0fbce6269dce4";
    sha256 = "1hxfn0n29a0lpfsfxg1nv7gm5ffdlb6vn9ks2abkfvqyrwkvf1j5";
  };
  racketThinBuildInputs = [ self."base" self."nested-hash" self."threading" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "split-by" = self.lib.mkRacketDerivation rec {
  pname = "split-by";
  src = fetchgit {
    name = "split-by";
    url = "git://github.com/samth/split-by.git";
    rev = "87fc10bda5e0394f78455a78183c3f3a16bc60df";
    sha256 = "1n7fs2q7ij4bllv4vwssfm26n1f3z8b51r040fk1wwfp9k3qccya";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "spmatrix" = self.lib.mkRacketDerivation rec {
  pname = "spmatrix";
  src = fetchgit {
    name = "spmatrix";
    url = "git://github.com/jeapostrophe/matrix.git";
    rev = "15e1c74f8763abbdfb4348702c98ca6043e52a1c";
    sha256 = "11prqwhnkw0xl68yw3fdc25mg5mqynzzvbl77mwzqzr2fri3b6rj";
  };
  racketThinBuildInputs = [ self."spvector" self."base" self."compatibility-lib" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "spreadsheet-editor" = self.lib.mkRacketDerivation rec {
  pname = "spreadsheet-editor";
  src = fetchgit {
    name = "spreadsheet-editor";
    url = "git://github.com/kugelblitz/spreadsheet-editor.git";
    rev = "73f8cfa89f0534f0bbb72833741cc7d5974ecda8";
    sha256 = "0slkr42ylpv6hddbcg2d4ci5zl1vvcgy1lxmh81j9ffw43w955wm";
  };
  racketThinBuildInputs = [ self."base" self."gui" self."draw-lib" self."data-lib" self."table-panel" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "spvector" = self.lib.mkRacketDerivation rec {
  pname = "spvector";
  src = fetchgit {
    name = "spvector";
    url = "git://github.com/jeapostrophe/spvector.git";
    rev = "aba0ba4f4d8df27dc17252b984eca2f76f4ae414";
    sha256 = "1znrwa38m9g5j97siv794br3abm4wh0gljjxp98p7lwsj0vsqwq2";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sql" = self.lib.mkRacketDerivation rec {
  pname = "sql";
  src = fetchgit {
    name = "sql";
    url = "git://github.com/rmculpepper/sql.git";
    rev = "792895fae759c6ef60aff054c1f707bb4f15407a";
    sha256 = "1370a1ldfr09i723n13bxh1dsjwj3yg19sh44g2hvmr0ji28y3ww";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."db-lib" self."racket-doc" self."scribble-lib" self."sandbox-lib" self."db-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sql-sourcery" = self.lib.mkRacketDerivation rec {
  pname = "sql-sourcery";
  src = self.lib.extractPath {
    path = "sql-sourcery";
    src = fetchgit {
    name = "sql-sourcery";
    url = "git://github.com/adjkant/sql-sourcery.git";
    rev = "f6c0619ed9febbb66864f36aa41fa495df683f95";
    sha256 = "1njwxpagk9wmzyp4al3hrkq30dfpcxlxchhqnk7228hmbnpyqnip";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sqlite-table" = self.lib.mkRacketDerivation rec {
  pname = "sqlite-table";
  src = fetchgit {
    name = "sqlite-table";
    url = "git://github.com/jbclements/sqlite-table.git";
    rev = "d1b892fe91a9413efd42da9ca75b5e1db5333993";
    sha256 = "0a0g2r11q9vwzhf3md7hndy9rdq45s0anzd34jxl3vh37qfhvav4";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "squicky" = self.lib.mkRacketDerivation rec {
  pname = "squicky";
  src = fetchurl {
    url = "http://nxg.me.uk/dist/squicky/squicky.zip";
    sha1 = "c73696e916f2b8c1ddcf90abff8aa5f3a91a1a4c";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."scribble-lib" self."srfi-lite-lib" self."at-exp-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi" = self.lib.mkRacketDerivation rec {
  pname = "srfi";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi.zip";
    sha1 = "0a51b570ae6fc85193ae87dbd2f4c30dc95b7636";
  };
  racketThinBuildInputs = [ self."srfi-lib" self."srfi-doc" self."srfi-doc-nonfree" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-doc" = self.lib.mkRacketDerivation rec {
  pname = "srfi-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi-doc.zip";
    sha1 = "3b7c81202cefe56599af810de8615a2cf1421aa8";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."scribble-lib" self."compatibility-lib" self."scheme-lib" self."base" self."scribble-lib" self."srfi-lib" self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-doc-nonfree" = self.lib.mkRacketDerivation rec {
  pname = "srfi-doc-nonfree";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi-doc-nonfree.zip";
    sha1 = "1ccf93e0fdf10ff61d529116e9670077e11cbf46";
  };
  racketThinBuildInputs = [ self."mzscheme-doc" self."scheme-lib" self."base" self."scribble-lib" self."srfi-doc" self."racket-doc" self."r5rs-doc" self."r6rs-doc" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-lib" = self.lib.mkRacketDerivation rec {
  pname = "srfi-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi-lib.zip";
    sha1 = "b751a0b6a0143cdf048338fdba1bd1e84690a510";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."srfi-lite-lib" self."r6rs-lib" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-lib-nonfree" = self.lib.mkRacketDerivation rec {
  pname = "srfi-lib-nonfree";
  src = self.lib.extractPath {
    path = "srfi-lib-nonfree";
    src = fetchgit {
    name = "srfi-lib-nonfree";
    url = "git://github.com/racket/srfi.git";
    rev = "bc905ddcbeaa84502a015f140ddecd0d2772d576";
    sha256 = "19ywzx1km5k7fzcvb2r7ymg0zh3344k7fr4cq8c817vzkz0327wp";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-lite-lib" = self.lib.mkRacketDerivation rec {
  pname = "srfi-lite-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi-lite-lib.zip";
    sha1 = "bc3411fc6d92cb08786bfa1540eb366611748249";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-test" = self.lib.mkRacketDerivation rec {
  pname = "srfi-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/srfi-test.zip";
    sha1 = "29a82de6251c2bd3ac8b43117093ec8b4784627c";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."rackunit-lib" self."srfi-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ss-rpc-server" = self.lib.mkRacketDerivation rec {
  pname = "ss-rpc-server";
  src = fetchgit {
    name = "ss-rpc-server";
    url = "git://github.com/sk1e/ss-rpc-server.git";
    rev = "50f281f251f06ea0b56955a275750aa170a94254";
    sha256 = "1xy9hrrawcrqaj1515cyq1qq5162qz75pazimdx521939chasm6l";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lite-lib" self."web-server-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ssh-hack" = self.lib.mkRacketDerivation rec {
  pname = "ssh-hack";
  src = fetchgit {
    name = "ssh-hack";
    url = "git://github.com/winny-/ssh-hack.git";
    rev = "9e8099a385fed26def70690279ad9d4ff3a097d0";
    sha256 = "0i9mrgmvahycmm6xr03mj1k9bjawy7pv23v7103q0k1q1rqbhlr0";
  };
  racketThinBuildInputs = [ self."base" self."ansi" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "staged-slide" = self.lib.mkRacketDerivation rec {
  pname = "staged-slide";
  src = fetchgit {
    name = "staged-slide";
    url = "git://github.com/stamourv/staged-slide.git";
    rev = "28b9389ea83984306dd50b634cb795c3bd86ca41";
    sha256 = "0czkq90ywrplnqkxk2xfx0c21cj1kdf6ksqn447fccrnllzgn7xz";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."slideshow-lib" self."scribble-lib" self."pict-doc" self."racket-doc" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stardate" = self.lib.mkRacketDerivation rec {
  pname = "stardate";
  src = fetchgit {
    name = "stardate";
    url = "git://github.com/dyoo/stardate.git";
    rev = "580558886983d73916c355e21400310a59729be5";
    sha256 = "0kh2p28npj93z7c41byzxq2pkc36nj0hpskyb11j0dhzrz0vb3yy";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "static-rename" = self.lib.mkRacketDerivation rec {
  pname = "static-rename";
  src = self.lib.extractPath {
    path = "static-rename";
    src = fetchgit {
    name = "static-rename";
    url = "git://github.com/lexi-lambda/racket-static-rename.git";
    rev = "50f1ff9866a3ef116471eb1a483c1992480dcd45";
    sha256 = "09gzqnlilws5hm7ayg1cc82maz72syxa52p0r89ayazxhw0yfmyx";
  };
  };
  racketThinBuildInputs = [ self."static-rename-doc" self."static-rename-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "static-rename-doc" = self.lib.mkRacketDerivation rec {
  pname = "static-rename-doc";
  src = self.lib.extractPath {
    path = "static-rename-doc";
    src = fetchgit {
    name = "static-rename-doc";
    url = "git://github.com/lexi-lambda/racket-static-rename.git";
    rev = "50f1ff9866a3ef116471eb1a483c1992480dcd45";
    sha256 = "09gzqnlilws5hm7ayg1cc82maz72syxa52p0r89ayazxhw0yfmyx";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."static-rename-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "static-rename-lib" = self.lib.mkRacketDerivation rec {
  pname = "static-rename-lib";
  src = self.lib.extractPath {
    path = "static-rename-lib";
    src = fetchgit {
    name = "static-rename-lib";
    url = "git://github.com/lexi-lambda/racket-static-rename.git";
    rev = "50f1ff9866a3ef116471eb1a483c1992480dcd45";
    sha256 = "09gzqnlilws5hm7ayg1cc82maz72syxa52p0r89ayazxhw0yfmyx";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "static-rename-test" = self.lib.mkRacketDerivation rec {
  pname = "static-rename-test";
  src = self.lib.extractPath {
    path = "static-rename-test";
    src = fetchgit {
    name = "static-rename-test";
    url = "git://github.com/lexi-lambda/racket-static-rename.git";
    rev = "50f1ff9866a3ef116471eb1a483c1992480dcd45";
    sha256 = "09gzqnlilws5hm7ayg1cc82maz72syxa52p0r89ayazxhw0yfmyx";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-spec" self."static-rename-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "statsd" = self.lib.mkRacketDerivation rec {
  pname = "statsd";
  src = fetchgit {
    name = "statsd";
    url = "git://github.com/apg/statsd-rkt.git";
    rev = "39a640686053be83442bfb129a279b8d00d6a177";
    sha256 = "1za8gi3gbcl5sshqnx23wgpsanrmk6k4dxrscxcrgnqcb5g74w3j";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stockfighter-racket" = self.lib.mkRacketDerivation rec {
  pname = "stockfighter-racket";
  src = fetchgit {
    name = "stockfighter-racket";
    url = "git://github.com/eu90h/stockfighter-racket.git";
    rev = "cf7669c2d79645a54ee287df14a3e704006e0096";
    sha256 = "0mjy18a5nxjw1mvdnb973rf4nyfkkc7hyy8zq323iiad78xx88gb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rfc6455" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stomp" = self.lib.mkRacketDerivation rec {
  pname = "stomp";
  src = fetchgit {
    name = "stomp";
    url = "git://github.com/tonyg/racket-stomp.git";
    rev = "8ec9471362f42253df787c83dc3f241086be6b9f";
    sha256 = "0hrqdsxssyp6ldrxv6z96v8kw3jj4gmy2ljp0ma0skan0nyp8r4y";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stream-values" = self.lib.mkRacketDerivation rec {
  pname = "stream-values";
  src = fetchgit {
    name = "stream-values";
    url = "git://github.com/sorawee/stream-values.git";
    rev = "a74e4cdb3beb9d9023dfd53b2c25364e5a1f910d";
    sha256 = "1c9nl94mzlfigy14wq6g4zmnbwryk9rnbblr4k24xn1ik8lb75rh";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stretchable-snip" = self.lib.mkRacketDerivation rec {
  pname = "stretchable-snip";
  src = fetchgit {
    name = "stretchable-snip";
    url = "git://github.com/Kalimehtar/stretchable-snip.git";
    rev = "5953118ad3b3e9d60b350d57b5b5c9a653ee1a14";
    sha256 = "0995hyf68ry95gik75v4al7myjk3fq2648xklnpfqw6vrkjmdhf1";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."draw-doc" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants" = self.lib.mkRacketDerivation rec {
  pname = "string-constants";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/string-constants.zip";
    sha1 = "c44db668e1449190a26e0597e8f5a2c7bd5f03bf";
  };
  racketThinBuildInputs = [ self."string-constants-lib" self."string-constants-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants-doc" = self.lib.mkRacketDerivation rec {
  pname = "string-constants-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/string-constants-doc.zip";
    sha1 = "a8c568616380ce22a8cbb9078609e5bc5028a265";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."string-constants-lib" self."base" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants-lib" = self.lib.mkRacketDerivation rec {
  pname = "string-constants-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/string-constants-lib.zip";
    sha1 = "a1efc10ad37b7792ad18fdc65fa6df8ea979dc6a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-sexpr" = self.lib.mkRacketDerivation rec {
  pname = "string-sexpr";
  src = fetchgit {
    name = "string-sexpr";
    url = "git://github.com/mfelleisen/string-sexpr.git";
    rev = "b87319d3c34be048df24222e54c7dc4327063dc8";
    sha256 = "1r749df8zxhyfas7rslflafxdlxfingl59lv1dp6xn5zhl1izzjz";
  };
  racketThinBuildInputs = [ self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-util" = self.lib.mkRacketDerivation rec {
  pname = "string-util";
  src = fetchgit {
    name = "string-util";
    url = "https://gitlab.com/RayRacine/string-util.git";
    rev = "4af2c3e5f21accaa4bc8f02db2bfe8f1b9a62223";
    sha256 = "16m931d278n2r1kxx5klwyb9wbark5z3jpqancswj3ssrhkrb63y";
  };
  racketThinBuildInputs = [ self."opt" self."list-util" self."srfi-lite-lib" self."typed-racket-more" self."typed-racket-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stripe-integration" = self.lib.mkRacketDerivation rec {
  pname = "stripe-integration";
  src = fetchgit {
    name = "stripe-integration";
    url = "git://github.com/zyrolasting/stripe-integration.git";
    rev = "8675b005992576a1df07f6687b271be026049eaa";
    sha256 = "1hlczsr013mkadjsjfdch7q2k68q9wy3qrigdkq2c8dv2q3k024s";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-defaults" = self.lib.mkRacketDerivation rec {
  pname = "struct-defaults";
  src = fetchgit {
    name = "struct-defaults";
    url = "git://github.com/tonyg/racket-struct-defaults.git";
    rev = "97fb427ab2210ba145486604b2095704c51da6a9";
    sha256 = "0c8igcgx9h5pp5497gny385kldrcjsy5pnxyhl5nknfy5aqfgfbp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-define" = self.lib.mkRacketDerivation rec {
  pname = "struct-define";
  src = fetchgit {
    name = "struct-define";
    url = "git://github.com/jeapostrophe/struct-define.git";
    rev = "6f109ba648ab5cc7c5fe59f98786af4516e368be";
    sha256 = "0rhg23yrrp9kayx2sph2ixkq6xjvv8d6kar95z2rw7479awvjbvm";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-like-struct-type-property" = self.lib.mkRacketDerivation rec {
  pname = "struct-like-struct-type-property";
  src = fetchgit {
    name = "struct-like-struct-type-property";
    url = "git://github.com/AlexKnauth/struct-like-struct-type-property.git";
    rev = "1d237f9b8e4bbc01e1aed05a73f23d2dbbb3614b";
    sha256 = "1lmj210vcxl2n8p5pxnqlypv46sl4na2vp6nmq4j6v5jrhlr4yfq";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-plus-plus" = self.lib.mkRacketDerivation rec {
  pname = "struct-plus-plus";
  src = fetchgit {
    name = "struct-plus-plus";
    url = "git://github.com/dstorrs/struct-plus-plus.git";
    rev = "79c771719f34efcc217a165597931d9d0a8aa004";
    sha256 = "1rg4q58m97mj3m7crs64q0lpysga1flghpkmnzhk2wi8mb58hm1f";
  };
  racketThinBuildInputs = [ self."base" self."handy" self."syntax-classes-lib" self."at-exp-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-update" = self.lib.mkRacketDerivation rec {
  pname = "struct-update";
  src = self.lib.extractPath {
    path = "struct-update";
    src = fetchgit {
    name = "struct-update";
    url = "git://github.com/lexi-lambda/struct-update.git";
    rev = "8ce456cde8764ae27c348123ec9e01e76826d536";
    sha256 = "14bmg0lchqy198wmbx05a8w5rpgk4rqagfg9izyj4dgkii9wrgzh";
  };
  };
  racketThinBuildInputs = [ self."base" self."struct-update-lib" self."struct-update-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-update-doc" = self.lib.mkRacketDerivation rec {
  pname = "struct-update-doc";
  src = self.lib.extractPath {
    path = "struct-update-doc";
    src = fetchgit {
    name = "struct-update-doc";
    url = "git://github.com/lexi-lambda/struct-update.git";
    rev = "8ce456cde8764ae27c348123ec9e01e76826d536";
    sha256 = "14bmg0lchqy198wmbx05a8w5rpgk4rqagfg9izyj4dgkii9wrgzh";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."struct-update-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-update-lib" = self.lib.mkRacketDerivation rec {
  pname = "struct-update-lib";
  src = self.lib.extractPath {
    path = "struct-update-lib";
    src = fetchgit {
    name = "struct-update-lib";
    url = "git://github.com/lexi-lambda/struct-update.git";
    rev = "8ce456cde8764ae27c348123ec9e01e76826d536";
    sha256 = "14bmg0lchqy198wmbx05a8w5rpgk4rqagfg9izyj4dgkii9wrgzh";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "struct-update-test" = self.lib.mkRacketDerivation rec {
  pname = "struct-update-test";
  src = self.lib.extractPath {
    path = "struct-update-test";
    src = fetchgit {
    name = "struct-update-test";
    url = "git://github.com/lexi-lambda/struct-update.git";
    rev = "8ce456cde8764ae27c348123ec9e01e76826d536";
    sha256 = "14bmg0lchqy198wmbx05a8w5rpgk4rqagfg9izyj4dgkii9wrgzh";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-spec" self."struct-update-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stxparse-info" = self.lib.mkRacketDerivation rec {
  pname = "stxparse-info";
  src = fetchgit {
    name = "stxparse-info";
    url = "git://github.com/jsmaniac/stxparse-info.git";
    rev = "c725ad4265a804e9161e4f2a6e53d5f7069c18fe";
    sha256 = "160rql287cmjg32zh6fka0h6zwapxpxjfns2dpky6mlmjy2nzkjd";
  };
  racketThinBuildInputs = [ self."stxparse-info+subtemplate" self."base" self."rackunit-lib" self."version-case" self."auto-syntax-e" self."compatibility-lib" self."scribble-lib" self."racket-doc" self."at-exp-lib" ];
  circularBuildInputs = [ "stxparse-info" "subtemplate" ];
  reverseCircularBuildInputs = [  ];
  };
  "stxparse-info+subtemplate" = self.lib.mkRacketDerivation rec {
  pname = "stxparse-info+subtemplate";

  extraSrcs = [ self."stxparse-info".src self."subtemplate".src ];
  racketThinBuildInputs = [ self."alexis-util" self."at-exp-lib" self."auto-syntax-e" self."backport-template-pr1514" self."base" self."compatibility-lib" self."phc-toolkit" self."racket-doc" self."rackunit-lib" self."scope-operations" self."scribble-lib" self."scribble-math" self."srfi-lite-lib" self."version-case" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "stxparse-info" "subtemplate" ];
  };
  "subtemplate" = self.lib.mkRacketDerivation rec {
  pname = "subtemplate";
  src = fetchgit {
    name = "subtemplate";
    url = "git://github.com/jsmaniac/subtemplate.git";
    rev = "a3292113bb0d7dd8dc2114702b90e76f23963496";
    sha256 = "15rwf96c5l37apazldyzsvqs9k3wxkd1sgyh5qhjcw03k68kgfjf";
  };
  racketThinBuildInputs = [ self."stxparse-info+subtemplate" self."base" self."rackunit-lib" self."backport-template-pr1514" self."phc-toolkit" self."srfi-lite-lib" self."alexis-util" self."scope-operations" self."auto-syntax-e" self."version-case" self."scribble-lib" self."racket-doc" self."scribble-math" ];
  circularBuildInputs = [ "stxparse-info" "subtemplate" ];
  reverseCircularBuildInputs = [  ];
  };
  "sudo" = self.lib.mkRacketDerivation rec {
  pname = "sudo";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/sudo.zip";
    sha1 = "b0fdd9113b261b7e117773be749e9c198f12f47d";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" self."overeasy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "suffixtree" = self.lib.mkRacketDerivation rec {
  pname = "suffixtree";
  src = fetchgit {
    name = "suffixtree";
    url = "git://github.com/jbclements/suffixtree.git";
    rev = "246b111906cae2718bc6452fa306680e00b03c41";
    sha256 = "150gg4pk5krrkaxph6yzymnilzdsjfmn4a7dw67s77fl6khfmv0i";
  };
  racketThinBuildInputs = [ self."base" self."plot-gui-lib" self."plot-lib" self."profile-lib" self."rackunit-lib" self."srfi-lite-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sugar" = self.lib.mkRacketDerivation rec {
  pname = "sugar";
  src = fetchgit {
    name = "sugar";
    url = "git://github.com/mbutterick/sugar.git";
    rev = "0613eafd85082473e0e2295ee349c3b691a51e13";
    sha256 = "1akjr6gqljpvyg7rnb7dhmhlxdh70rnrzq1mpx9cgc0d6v1ldvcr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "superc" = self.lib.mkRacketDerivation rec {
  pname = "superc";
  src = fetchgit {
    name = "superc";
    url = "git://github.com/jeapostrophe/superc.git";
    rev = "929d3e32db7a5c69fa9e033db7b5707cff329672";
    sha256 = "1scsny08a2z7ivsc18lv7fdjcg93rkb2ci2h69k06rw4zmbkxcjn";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."scribble-text-lib" self."scheme-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "superv" = self.lib.mkRacketDerivation rec {
  pname = "superv";
  src = fetchgit {
    name = "superv";
    url = "git://github.com/sleibrock/superv.git";
    rev = "23a7132484f293c3ca407db5b3e86a9e0a7a9708";
    sha256 = "19x4gk6wv75gfv49cg59rkwdj2x1gf1m3lk9kyb3ggvjsqbpgl2b";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sweet-exp" = self.lib.mkRacketDerivation rec {
  pname = "sweet-exp";
  src = self.lib.extractPath {
    path = "sweet-exp";
    src = fetchgit {
    name = "sweet-exp";
    url = "git://github.com/takikawa/sweet-racket.git";
    rev = "a3c1ae74c2e75e8d6164a3a9d8eb34335a7ba4de";
    sha256 = "0rwq63miz95s15zg4h7mnxp1ibwxh2mq4hzn78rr16bqp8r2dbam";
  };
  };
  racketThinBuildInputs = [ self."base" self."sweet-exp-lib" self."sweet-exp-test" self."scribble-lib" self."racket-doc" self."scribble-doc" self."lazy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sweet-exp-lib" = self.lib.mkRacketDerivation rec {
  pname = "sweet-exp-lib";
  src = self.lib.extractPath {
    path = "sweet-exp-lib";
    src = fetchgit {
    name = "sweet-exp-lib";
    url = "git://github.com/takikawa/sweet-racket.git";
    rev = "a3c1ae74c2e75e8d6164a3a9d8eb34335a7ba4de";
    sha256 = "0rwq63miz95s15zg4h7mnxp1ibwxh2mq4hzn78rr16bqp8r2dbam";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sweet-exp-test" = self.lib.mkRacketDerivation rec {
  pname = "sweet-exp-test";
  src = self.lib.extractPath {
    path = "sweet-exp-test";
    src = fetchgit {
    name = "sweet-exp-test";
    url = "git://github.com/takikawa/sweet-racket.git";
    rev = "a3c1ae74c2e75e8d6164a3a9d8eb34335a7ba4de";
    sha256 = "0rwq63miz95s15zg4h7mnxp1ibwxh2mq4hzn78rr16bqp8r2dbam";
  };
  };
  racketThinBuildInputs = [ self."base" self."sweet-exp-lib" self."rackunit-lib" self."lazy" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "swindle" = self.lib.mkRacketDerivation rec {
  pname = "swindle";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/swindle.zip";
    sha1 = "327a5befb4bf60b24283917b35e493a974064ecf";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."string-constants-lib" self."compatibility-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sxml" = self.lib.mkRacketDerivation rec {
  pname = "sxml";
  src = fetchgit {
    name = "sxml";
    url = "git://github.com/jbclements/sxml.git";
    rev = "b514818c106a818c8aca951d50fa24af0d8323a0";
    sha256 = "03b1yxd7rv85xlcjm2x2sgsng8zdzf1flhl1lnq94rpa1yql0ji1";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sxml-intro" = self.lib.mkRacketDerivation rec {
  pname = "sxml-intro";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/sxml-intro.zip";
    sha1 = "f3ad1b1a3be60c165f74c0d8668de44fbf8a9137";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "symalg" = self.lib.mkRacketDerivation rec {
  pname = "symalg";
  src = fetchgit {
    name = "symalg";
    url = "git://github.com/pyohannes/racket-symalg.git";
    rev = "5c551e9fcead240dcc70261563c5b981428ca67a";
    sha256 = "1622hv6j570098599jrk6sgb84jklv9bcfj7am4z9i9bls3avx3m";
  };
  racketThinBuildInputs = [ self."base" self."multimethod" self."parser-tools" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syndicate" = self.lib.mkRacketDerivation rec {
  pname = "syndicate";
  src = self.lib.extractPath {
    path = "racket/";
    src = fetchgit {
    name = "syndicate";
    url = "git://github.com/tonyg/syndicate.git";
    rev = "af8dbeaa4bfd1faf74e68911a4dd992cd9a9b1fc";
    sha256 = "0kahvyzlscr63dwj93wfb4qcrj7lmzlsmwb8nwj5f9bc0dmpjs8g";
  };
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."htdp-lib" self."net-lib" self."profile-lib" self."rackunit-lib" self."sha" self."automata" self."auxiliary-macro-context" self."data-enumerate-lib" self."datalog" self."db-lib" self."draw-lib" self."gui-lib" self."images-lib" self."macrotypes-lib" self."pict-lib" self."rackunit-macrotypes-lib" self."rfc6455" self."sandbox-lib" self."sgl" self."struct-defaults" self."turnstile-example" self."turnstile-lib" self."web-server-lib" self."draw-doc" self."gui-doc" self."htdp-doc" self."pict-doc" self."racket-doc" self."scribble-lib" self."sha" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-class-or" = self.lib.mkRacketDerivation rec {
  pname = "syntax-class-or";
  src = fetchgit {
    name = "syntax-class-or";
    url = "git://github.com/AlexKnauth/syntax-class-or.git";
    rev = "948a823026cb462f113400b5deb5276c9bd1846a";
    sha256 = "1788mij9ilvkvp6imjsk2x4h5ci4360j7h0g7cmh4h16fyvzaram";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-classes" = self.lib.mkRacketDerivation rec {
  pname = "syntax-classes";
  src = self.lib.extractPath {
    path = "syntax-classes";
    src = fetchgit {
    name = "syntax-classes";
    url = "git://github.com/lexi-lambda/syntax-classes.git";
    rev = "a8a95ede1c72d7dae0764437126f5ce9bbe7967a";
    sha256 = "03x3rd2wb2kdmw9baklryxs3f72v23apq5iqmnf99yll3vijmycf";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes-lib" self."syntax-classes-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-classes-doc" = self.lib.mkRacketDerivation rec {
  pname = "syntax-classes-doc";
  src = self.lib.extractPath {
    path = "syntax-classes-doc";
    src = fetchgit {
    name = "syntax-classes-doc";
    url = "git://github.com/lexi-lambda/syntax-classes.git";
    rev = "9498cdfcf949b277ebef3d69062ae024f2005380";
    sha256 = "1n8524z6b5bhf8zz84f978iyvsl4dpqc58p69si06gimrirgvklp";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-classes-lib" = self.lib.mkRacketDerivation rec {
  pname = "syntax-classes-lib";
  src = self.lib.extractPath {
    path = "syntax-classes-lib";
    src = fetchgit {
    name = "syntax-classes-lib";
    url = "git://github.com/lexi-lambda/syntax-classes.git";
    rev = "a8a95ede1c72d7dae0764437126f5ce9bbe7967a";
    sha256 = "03x3rd2wb2kdmw9baklryxs3f72v23apq5iqmnf99yll3vijmycf";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-classes-test" = self.lib.mkRacketDerivation rec {
  pname = "syntax-classes-test";
  src = self.lib.extractPath {
    path = "syntax-classes-test";
    src = fetchgit {
    name = "syntax-classes-test";
    url = "git://github.com/lexi-lambda/syntax-classes.git";
    rev = "a8a95ede1c72d7dae0764437126f5ce9bbe7967a";
    sha256 = "03x3rd2wb2kdmw9baklryxs3f72v23apq5iqmnf99yll3vijmycf";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-spec" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/syntax-color.zip";
    sha1 = "470aa2e55eb4b645a37513f7a4ceb1eaf6283082";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."syntax-color-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-doc" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/syntax-color-doc.zip";
    sha1 = "2b6f59ee433b8fe2e0e07433a67a932557139281";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."gui-lib" self."scribble-lib" self."syntax-color-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-lib" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/syntax-color-lib.zip";
    sha1 = "f1d69d7143c5afb925489a0cb2559ad119d8cf7e";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."parser-tools-lib" self."option-contract-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-test" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/syntax-color-test.zip";
    sha1 = "619361bcaac65edcc8149274c1aee26c2d0700bb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scheme-lib" self."syntax-color-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-highlighting" = self.lib.mkRacketDerivation rec {
  pname = "syntax-highlighting";
  src = fetchgit {
    name = "syntax-highlighting";
    url = "git://github.com/zyrolasting/syntax-highlighting.git";
    rev = "13d2d0019bb44cbaca2d50eee1eb4c7d5f9fa701";
    sha256 = "1a8pqwn1p0zx96pbq8paq9qxh7vg1k1fxrsr2pag46a8d3m53rlk";
  };
  racketThinBuildInputs = [ self."base" self."parsack" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-lang" = self.lib.mkRacketDerivation rec {
  pname = "syntax-lang";
  src = fetchgit {
    name = "syntax-lang";
    url = "git://github.com/jackfirth/racket-syntax-lang.git";
    rev = "50897fef061bcf8640110a7695c81a3a06e38e6d";
    sha256 = "14ai9r55vfnsfhr6662l1agrnwvmh92ffnhq1yq674drr1049nz0";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-macro-lang" = self.lib.mkRacketDerivation rec {
  pname = "syntax-macro-lang";
  src = fetchgit {
    name = "syntax-macro-lang";
    url = "git://github.com/AlexKnauth/syntax-macro-lang.git";
    rev = "fad6fd9c44ea20335b03e820b06b042883bb40bf";
    sha256 = "0fdnhr41zydh4qamyxdvfjq6nfxdg8aaxfjdgx53yrqb0gcnkn3j";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-parse-example" = self.lib.mkRacketDerivation rec {
  pname = "syntax-parse-example";
  src = fetchgit {
    name = "syntax-parse-example";
    url = "git://github.com/bennn/syntax-parse-example.git";
    rev = "e76436d7e2068b970bde5b241636d8660912efcb";
    sha256 = "0814qxsv1jd32xr7gwa50qhrqj695mly6v046i1zlvnaa9hx4gkj";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."scribble-lib" self."rackunit-lib" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."rackunit-doc" self."rackunit-lib" self."scribble-doc" self."rackunit-typed" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-sloc" = self.lib.mkRacketDerivation rec {
  pname = "syntax-sloc";
  src = fetchgit {
    name = "syntax-sloc";
    url = "git://github.com/AlexKnauth/syntax-sloc.git";
    rev = "ea9bfa06a207ba63b481dcc794c55475eb6bcc33";
    sha256 = "156rmzywjld6lf0cj8lwskgrn49ij45h1jhcj4dhrzqbyws4acgv";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."lang-file" self."rackunit-lib" self."scribble-lib" self."scribble-code-examples" self."racket-doc" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-warn" = self.lib.mkRacketDerivation rec {
  pname = "syntax-warn";
  src = self.lib.extractPath {
    path = "syntax-warn";
    src = fetchgit {
    name = "syntax-warn";
    url = "git://github.com/jackfirth/syntax-warn.git";
    rev = "f17fdd3179aeab8e5275a24e7d091d3ca42960a9";
    sha256 = "1isbp3lzhaqqjy0r1av6mkfsb35qqyggng5w7gm0zsk1hic1v07l";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-warn-base" self."syntax-warn-cli" self."syntax-warn-doc" self."syntax-warn-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-warn-base" = self.lib.mkRacketDerivation rec {
  pname = "syntax-warn-base";
  src = self.lib.extractPath {
    path = "syntax-warn-base";
    src = fetchgit {
    name = "syntax-warn-base";
    url = "git://github.com/jackfirth/syntax-warn.git";
    rev = "f17fdd3179aeab8e5275a24e7d091d3ca42960a9";
    sha256 = "1isbp3lzhaqqjy0r1av6mkfsb35qqyggng5w7gm0zsk1hic1v07l";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-warn-cli" = self.lib.mkRacketDerivation rec {
  pname = "syntax-warn-cli";
  src = self.lib.extractPath {
    path = "syntax-warn-cli";
    src = fetchgit {
    name = "syntax-warn-cli";
    url = "git://github.com/jackfirth/syntax-warn.git";
    rev = "f17fdd3179aeab8e5275a24e7d091d3ca42960a9";
    sha256 = "1isbp3lzhaqqjy0r1av6mkfsb35qqyggng5w7gm0zsk1hic1v07l";
  };
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."syntax-warn-lang" self."base" self."compiler-lib" self."syntax-warn-base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-warn-doc" = self.lib.mkRacketDerivation rec {
  pname = "syntax-warn-doc";
  src = self.lib.extractPath {
    path = "syntax-warn-doc";
    src = fetchgit {
    name = "syntax-warn-doc";
    url = "git://github.com/jackfirth/syntax-warn.git";
    rev = "f17fdd3179aeab8e5275a24e7d091d3ca42960a9";
    sha256 = "1isbp3lzhaqqjy0r1av6mkfsb35qqyggng5w7gm0zsk1hic1v07l";
  };
  };
  racketThinBuildInputs = [ self."syntax-warn-base" self."scribble-lib" self."scribble-text-lib" self."base" self."racket-doc" self."scribble-lib" self."syntax-warn-base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-warn-lang" = self.lib.mkRacketDerivation rec {
  pname = "syntax-warn-lang";
  src = self.lib.extractPath {
    path = "syntax-warn-lang";
    src = fetchgit {
    name = "syntax-warn-lang";
    url = "git://github.com/jackfirth/syntax-warn.git";
    rev = "f17fdd3179aeab8e5275a24e7d091d3ca42960a9";
    sha256 = "1isbp3lzhaqqjy0r1av6mkfsb35qqyggng5w7gm0zsk1hic1v07l";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-warn-base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sysfs" = self.lib.mkRacketDerivation rec {
  pname = "sysfs";
  src = fetchgit {
    name = "sysfs";
    url = "git://github.com/mordae/racket-sysfs.git";
    rev = "80a68016bfd28fa5e86269e7bae0cbbe5ad8de87";
    sha256 = "0g6f38n60ivkvszvpn352q1ylmynkkg0krh37ajhhy3k1qii23jh";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "systemd" = self.lib.mkRacketDerivation rec {
  pname = "systemd";
  src = fetchgit {
    name = "systemd";
    url = "git://github.com/mordae/racket-systemd.git";
    rev = "fd389e3d6369aeae47004deef9d1d93018db7da4";
    sha256 = "143fzaflys8l48vdq1phqziyy9si57gn2p57ddrkiw1wglfgf7ph";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."libuuid" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "t-test" = self.lib.mkRacketDerivation rec {
  pname = "t-test";
  src = fetchgit {
    name = "t-test";
    url = "git://github.com/jbclements/t-test.git";
    rev = "eb5cc28868689324f6c27722d2516715570cab97";
    sha256 = "16m6vd80nw8ab5jzhw98zhynh6wjz8788p39npslq1w3a4cai4d2";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."typed-racket-lib" self."racket-doc" self."rackunit-typed" self."scribble-lib" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "table-panel" = self.lib.mkRacketDerivation rec {
  pname = "table-panel";
  src = fetchgit {
    name = "table-panel";
    url = "git://github.com/spdegabrielle/table-panel.git";
    rev = "e5994d6b0e11bae486679af2bcfa38442f0e5093";
    sha256 = "0yfp3nq9lj2qlwh1v5kgnilyhg0szhsxdq7rk86s3rh9z0gxbl89";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui" self."srfi-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tablesci" = self.lib.mkRacketDerivation rec {
  pname = "tablesci";
  src = fetchgit {
    name = "tablesci";
    url = "https://gitlab.com/hashimmm/tablesci.git";
    rev = "43c4544d64e9d218acabe167bfa3c894fa6f5f42";
    sha256 = "1yihl8jay4nglf96pkkl41g3hid4axrz1jj86gcs0bcf1ips2jpw";
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."brag-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tabular" = self.lib.mkRacketDerivation rec {
  pname = "tabular";
  src = fetchgit {
    name = "tabular";
    url = "git://github.com/tonyg/racket-tabular.git";
    rev = "5b1e3687dd27660f8bd3ecc10d52e8d57b150ff4";
    sha256 = "1rv5dji9dxyswycjrm1bdc2jf3ms03ai976nv1pvin4dch8rf872";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."data-lib" self."htdp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "taglib" = self.lib.mkRacketDerivation rec {
  pname = "taglib";
  src = fetchgit {
    name = "taglib";
    url = "git://github.com/takikawa/taglib-racket.git";
    rev = "69b0494bac4cf2d4c6b99701c7b586bdb827a0a3";
    sha256 = "07ag4ppy757qzr81yavwh9lfakqas3429kwiqaminv56fhbmz603";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "talk-typer" = self.lib.mkRacketDerivation rec {
  pname = "talk-typer";
  src = fetchgit {
    name = "talk-typer";
    url = "git://github.com/florence/talk-typer.git";
    rev = "24c5779e4d5b9548f96ac66d7c638c9bef0e7428";
    sha256 = "10gdsnarwvs7q1pbf6swhl36dl513i065q542qvafycf8n934l73";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."data-lib" self."drracket-plugin-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tandem" = self.lib.mkRacketDerivation rec {
  pname = "tandem";
  src = fetchgit {
    name = "tandem";
    url = "git://github.com/mordae/racket-tandem.git";
    rev = "fa6bae480f6f4a3ae411ca5c3bad7ae5f8d106ac";
    sha256 = "06vdfigil34svqjh3qqq4cniws3818nin1r6ym5l8wqxw7xac4xk";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "taskibble" = self.lib.mkRacketDerivation rec {
  pname = "taskibble";
  src = fetchgit {
    name = "taskibble";
    url = "git://github.com/sorpaas/taskibble.git";
    rev = "c333907e04ab23b0a79cd7c763f691dd743897ac";
    sha256 = "1qrdf3yn0lxkqd50kq5brnn1f8p6s0hf7h4zbiq5cfgbhrpsyj56";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."planet-lib" self."net-lib" self."at-exp-lib" self."draw-lib" self."syntax-color-lib" self."sandbox-lib" self."typed-racket-lib" self."datalog" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tasks" = self.lib.mkRacketDerivation rec {
  pname = "tasks";
  src = fetchgit {
    name = "tasks";
    url = "git://github.com/mordae/racket-tasks.git";
    rev = "2d2e1e096fec61da49531a86421d7e7eb4a9f3df";
    sha256 = "16k9b21nazyag1jqsdix4jwx89kczkl1vr5x7cvi6jv5a9k4w626";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "teachpacks" = self.lib.mkRacketDerivation rec {
  pname = "teachpacks";
  src = fetchgit {
    name = "teachpacks";
    url = "git://github.com/tyynetyyne/teachpacks.git";
    rev = "f82605dc2de7e6b6267fe2b2e6a6481a1ab33a35";
    sha256 = "1l84b60j0lcfaz7y0hp30s84c4sigfqfwq6y11draxcjn9qxpbw0";
  };
  racketThinBuildInputs = [ self."gui-lib" self."base" self."htdp-lib" self."plot-gui-lib" self."plot-lib" self."scribble-lib" self."scribble-doc" self."htdp-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "temp-c" = self.lib.mkRacketDerivation rec {
  pname = "temp-c";
  src = self.lib.extractPath {
    path = "temp-c";
    src = fetchgit {
    name = "temp-c";
    url = "git://github.com/jeapostrophe/temp-c.git";
    rev = "43f7f2141c81a301aa229ef4105f458eee070653";
    sha256 = "0wfidwr35dwx2hp22q0gp2cw5phnb72mczm68jbhfwzfxiiryd1b";
  };
  };
  racketThinBuildInputs = [ self."temp-c-lib" self."temp-c-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "temp-c-doc" = self.lib.mkRacketDerivation rec {
  pname = "temp-c-doc";
  src = self.lib.extractPath {
    path = "temp-c-doc";
    src = fetchgit {
    name = "temp-c-doc";
    url = "git://github.com/jeapostrophe/temp-c.git";
    rev = "43f7f2141c81a301aa229ef4105f458eee070653";
    sha256 = "0wfidwr35dwx2hp22q0gp2cw5phnb72mczm68jbhfwzfxiiryd1b";
  };
  };
  racketThinBuildInputs = [ self."base" self."temp-c-lib" self."scribble-lib" self."automata" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "temp-c-lib" = self.lib.mkRacketDerivation rec {
  pname = "temp-c-lib";
  src = self.lib.extractPath {
    path = "temp-c-lib";
    src = fetchgit {
    name = "temp-c-lib";
    url = "git://github.com/jeapostrophe/temp-c.git";
    rev = "43f7f2141c81a301aa229ef4105f458eee070653";
    sha256 = "0wfidwr35dwx2hp22q0gp2cw5phnb72mczm68jbhfwzfxiiryd1b";
  };
  };
  racketThinBuildInputs = [ self."base" self."automata-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "temp-c-test" = self.lib.mkRacketDerivation rec {
  pname = "temp-c-test";
  src = self.lib.extractPath {
    path = "temp-c-test";
    src = fetchgit {
    name = "temp-c-test";
    url = "git://github.com/jeapostrophe/temp-c.git";
    rev = "43f7f2141c81a301aa229ef4105f458eee070653";
    sha256 = "0wfidwr35dwx2hp22q0gp2cw5phnb72mczm68jbhfwzfxiiryd1b";
  };
  };
  racketThinBuildInputs = [ self."base" self."temp-c-lib" self."eli-tester" self."errortrace-lib" self."racket-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "template" = self.lib.mkRacketDerivation rec {
  pname = "template";
  src = fetchgit {
    name = "template";
    url = "git://github.com/dedbox/racket-template.git";
    rev = "7e8cd438cdc168b74b1a23721d3410be330de209";
    sha256 = "1cdg31q2p7gngz49xyz82cjjmaddfc0v1hqq6jmhjmi234i1waly";
  };
  racketThinBuildInputs = [ self."base" self."debug-scopes" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "terminal-phase" = self.lib.mkRacketDerivation rec {
  pname = "terminal-phase";
  src = fetchgit {
    name = "terminal-phase";
    url = "https://gitlab.com/dustyweb/terminal-phase.git";
    rev = "8d7d50b464a309bf2bee773b174274b745e68d1e";
    sha256 = "1hq8a9vm4bv0zx7xh6r2vdv5vgscvnif8w3wk1hjql8rvbw2s0vn";
  };
  racketThinBuildInputs = [ self."lux" self."goblins" self."pk" self."raart" self."ansi" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "termination" = self.lib.mkRacketDerivation rec {
  pname = "termination";
  src = self.lib.extractPath {
    path = "termination";
    src = fetchgit {
    name = "termination";
    url = "git://github.com/philnguyen/termination.git";
    rev = "1d05c1bf8e9bd59d2fbaaa213b490fd8e59644bd";
    sha256 = "0xkj8hc6jibi6r8pjwfybz426w2i85wzvl85npd9mbljp30xfpyn";
  };
  };
  racketThinBuildInputs = [ self."profile-lib" self."r5rs-lib" self."rackunit-lib" self."base" self."typed-racket-lib" self."typed-racket-more" self."bnf" self."set-extras" self."unreachable" self."traces" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "termios" = self.lib.mkRacketDerivation rec {
  pname = "termios";
  src = fetchgit {
    name = "termios";
    url = "git://github.com/BartAdv/racket-termios.git";
    rev = "b6632c54c587577c0cce86e62a72e9b09c38342e";
    sha256 = "0i7lyqxclkkk6g1300w6k8gp2fs4h41wybrqxz4mv60l80k2id15";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tesira" = self.lib.mkRacketDerivation rec {
  pname = "tesira";
  src = fetchgit {
    name = "tesira";
    url = "git://github.com/mordae/racket-tesira.git";
    rev = "47ae8cd92ad3b2610a3f95db9ba3e16db6b24d48";
    sha256 = "189crg5zndkmf48yqlic3z0afpvab3j7ii50n541k1fx1iyr7gp5";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."typed-racket-lib" self."parser-tools-lib" self."typed-racket-more" self."mordae" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "test-more" = self.lib.mkRacketDerivation rec {
  pname = "test-more";
  src = fetchgit {
    name = "test-more";
    url = "git://github.com/dstorrs/racket-test-more.git";
    rev = "659c90a27ffd575bf95b0eb60ec594a3e7420f16";
    sha256 = "0rf3hcnifv4zrwc3jm41bk1d3j1bnvhpmq9i7424wnscdj7agiir";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "testing-util-lib" = self.lib.mkRacketDerivation rec {
  pname = "testing-util-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/testing-util-lib.zip";
    sha1 = "182a865a3358425876dd6d7f00134795f62eea77";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tesurell" = self.lib.mkRacketDerivation rec {
  pname = "tesurell";
  src = fetchgit {
    name = "tesurell";
    url = "git://github.com/zyrolasting/tesurell.git";
    rev = "e4010930062d0741081ddb454d4c749e6754672d";
    sha256 = "07lffzz7001mnmaswzff1b8msx3q55g9mxvl14mlgc3w14c95diy";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."at-exp-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tetris" = self.lib.mkRacketDerivation rec {
  pname = "tetris";
  src = fetchgit {
    name = "tetris";
    url = "git://github.com/mosceo/tetris.git";
    rev = "fd8ea2d3b2d9374d2a4a88b6e01382f0eba9cbcb";
    sha256 = "1wb1sknlzyxwnz1cii8qm1ijycszisn0qyyw7hvxl6k01ck6904d";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tex-table" = self.lib.mkRacketDerivation rec {
  pname = "tex-table";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/tex-table.zip";
    sha1 = "7340fdf252356f1342d21bf337182be7fb974f8a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "texmath" = self.lib.mkRacketDerivation rec {
  pname = "texmath";
  src = fetchgit {
    name = "texmath";
    url = "git://github.com/dedbox/racket-texmath.git";
    rev = "9c775542b5473ed6aeedc7c45ecc6726fbd483fc";
    sha256 = "1r99lfqf4lqz2cl7al1lvqf2kdjhzail64acznblg79kfqmmlgnk";
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" self."megaparsack-lib" self."scribble-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "text-table" = self.lib.mkRacketDerivation rec {
  pname = "text-table";
  src = fetchgit {
    name = "text-table";
    url = "git://github.com/Metaxal/text-table.git";
    rev = "a2f437cd1488a699ec56baf308eff4dad4828798";
    sha256 = "1ya1j0qhipp170f6dp5a3f5vqp5pmpiqrqi02va0yp5nrwfcd719";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "the-unicoder" = self.lib.mkRacketDerivation rec {
  pname = "the-unicoder";
  src = fetchgit {
    name = "the-unicoder";
    url = "git://github.com/willghatch/the-unicoder.git";
    rev = "4eb4c074c6411a059a0bbaba5c1486c3b335d369";
    sha256 = "01l9b9ljph9fbwqw06cr1ml1yx66v7zssj16wz69d9zspjdgqry8";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."unix-socket-lib" self."tex-table" self."basedir" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "this-and-that" = self.lib.mkRacketDerivation rec {
  pname = "this-and-that";
  src = fetchgit {
    name = "this-and-that";
    url = "git://github.com/soegaard/this-and-that.git";
    rev = "bb2afd0834f6fdbc3cb8a9867e2a307063f38b80";
    sha256 = "0ayby3jg1mdyd3fklmjsbhhfnckjlahwrc3n4gxffcbkn57zpycv";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "thread-utils" = self.lib.mkRacketDerivation rec {
  pname = "thread-utils";
  src = fetchgit {
    name = "thread-utils";
    url = "git://github.com/Kalimehtar/thread-utils.git";
    rev = "f81ebfaf8453acb3a938917c1a505c94af92ef87";
    sha256 = "13szwkigk0wwzqhdpwi2m2sd93c9rmh6xzib53n3wcbai08fms7m";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "threading" = self.lib.mkRacketDerivation rec {
  pname = "threading";
  src = self.lib.extractPath {
    path = "threading";
    src = fetchgit {
    name = "threading";
    url = "git://github.com/lexi-lambda/threading.git";
    rev = "13a34f14fe073c328e5cc083c616a602a79afa58";
    sha256 = "10c1yj3nlq1dqgal6dzsw8g9mks3dfxdnyksc550w7wvz42habgl";
  };
  };
  racketThinBuildInputs = [ self."threading-doc" self."threading-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "threading-doc" = self.lib.mkRacketDerivation rec {
  pname = "threading-doc";
  src = self.lib.extractPath {
    path = "threading-doc";
    src = fetchgit {
    name = "threading-doc";
    url = "git://github.com/lexi-lambda/threading.git";
    rev = "13a34f14fe073c328e5cc083c616a602a79afa58";
    sha256 = "10c1yj3nlq1dqgal6dzsw8g9mks3dfxdnyksc550w7wvz42habgl";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."threading-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "threading-lib" = self.lib.mkRacketDerivation rec {
  pname = "threading-lib";
  src = self.lib.extractPath {
    path = "threading-lib";
    src = fetchgit {
    name = "threading-lib";
    url = "git://github.com/lexi-lambda/threading.git";
    rev = "13a34f14fe073c328e5cc083c616a602a79afa58";
    sha256 = "10c1yj3nlq1dqgal6dzsw8g9mks3dfxdnyksc550w7wvz42habgl";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "thrift" = self.lib.mkRacketDerivation rec {
  pname = "thrift";
  src = fetchgit {
    name = "thrift";
    url = "git://github.com/johnstonskj/racket-thrift.git";
    rev = "bbed34e6af97167ec5e9327c7c6ad739e331e793";
    sha256 = "140kb7zkd08l1iiwkd3jqaslmxsxhs4sd29mhihas7j4bl5yik97";
  };
  racketThinBuildInputs = [ self."base" self."http" self."unix-socket-lib" self."rackunit-lib" self."racket-index" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tightlight" = self.lib.mkRacketDerivation rec {
  pname = "tightlight";
  src = fetchurl {
    url = "https://www.cs.toronto.edu/~gfb/racket-pkgs/tightlight.zip";
    sha1 = "97cfd6a147b607117dfd654808563754741a566e";
  };
  racketThinBuildInputs = [ self."base" self."drracket-plugin-lib" self."gui-lib" self."snack" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "timable" = self.lib.mkRacketDerivation rec {
  pname = "timable";
  src = fetchgit {
    name = "timable";
    url = "git://github.com/yanyingwang/timable.git";
    rev = "2b2fd99e6e2f0a3dbfcb8cd3e6554df29681f82f";
    sha256 = "14zkalv6d0f11ddwdxj5bk44msnw0xq7h6i73pbs8ka1x1ql333w";
  };
  racketThinBuildInputs = [ self."base" self."srfi" self."gregor" self."db" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tjson" = self.lib.mkRacketDerivation rec {
  pname = "tjson";
  src = fetchgit {
    name = "tjson";
    url = "https://gitlab.com/RayRacine/tjson.git";
    rev = "b8471434b51592d3fcab819bb203380c8ede5de3";
    sha256 = "114qb5lvmbwng7hk986g3jwf45dmx9wgbnshg1qbw3kz1gbd01n2";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-more" self."typed-racket-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "todo-list" = self.lib.mkRacketDerivation rec {
  pname = "todo-list";
  src = fetchgit {
    name = "todo-list";
    url = "git://github.com/david-christiansen/todo-list.git";
    rev = "589e9c8f58f4684eae64d3254bdbad0b1bcaae39";
    sha256 = "00p2nnnpp8hjmsnwpvh8hv36g8vx84ksx1aihk9sabfgkf5jrw7k";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."drracket-plugin-lib" self."gui-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tomato-timer" = self.lib.mkRacketDerivation rec {
  pname = "tomato-timer";
  src = fetchgit {
    name = "tomato-timer";
    url = "git://github.com/bennn/tomato-timer.git";
    rev = "23254a8138d5fad885f3b7033fb89549cb268b50";
    sha256 = "1lw2alazryn10wf5qvs3qshs0l26whgs2bijc0lfr9rn646wqm6m";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "towers" = self.lib.mkRacketDerivation rec {
  pname = "towers";
  src = self.lib.extractPath {
    path = "towers";
    src = fetchgit {
    name = "towers";
    url = "git://github.com/Metaxal/towers.git";
    rev = "e1224228b5b5b514c7063b44810c1bdd5f8d5d14";
    sha256 = "1ip1sr61415zfg3pkcdx18zsxaknb1r8hna90f2ypcvag3wvbp0w";
  };
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."net-lib" self."bazaar" self."towers-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "towers-lib" = self.lib.mkRacketDerivation rec {
  pname = "towers-lib";
  src = self.lib.extractPath {
    path = "towers-lib";
    src = fetchgit {
    name = "towers-lib";
    url = "git://github.com/Metaxal/towers.git";
    rev = "e1224228b5b5b514c7063b44810c1bdd5f8d5d14";
    sha256 = "1ip1sr61415zfg3pkcdx18zsxaknb1r8hna90f2ypcvag3wvbp0w";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."bazaar" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "towers-server" = self.lib.mkRacketDerivation rec {
  pname = "towers-server";
  src = self.lib.extractPath {
    path = "towers-server";
    src = fetchgit {
    name = "towers-server";
    url = "git://github.com/Metaxal/towers.git";
    rev = "e1224228b5b5b514c7063b44810c1bdd5f8d5d14";
    sha256 = "1ip1sr61415zfg3pkcdx18zsxaknb1r8hna90f2ypcvag3wvbp0w";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."web-server-lib" self."bazaar" self."towers-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tr-immutable" = self.lib.mkRacketDerivation rec {
  pname = "tr-immutable";
  src = fetchgit {
    name = "tr-immutable";
    url = "git://github.com/jsmaniac/tr-immutable.git";
    rev = "da227b14ca63e1e1a9aaae07e94471202aaaaf26";
    sha256 = "1mhvbhfbxlpj2j26x8hxgbdq3ir5higji1rv4701b27s7jaimbqh";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-map-lib" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "trace" = self.lib.mkRacketDerivation rec {
  pname = "trace";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/trace.zip";
    sha1 = "b9247f6461d50745f75de2e68063dd6b420a1a52";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."compatibility-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "traces" = self.lib.mkRacketDerivation rec {
  pname = "traces";
  src = self.lib.extractPath {
    path = "traces";
    src = fetchgit {
    name = "traces";
    url = "git://github.com/philnguyen/traces.git";
    rev = "de08fadc1b1d73362c7b6d83f0dd9a4c9dc36743";
    sha256 = "08w40qm5sk0dk495lkqg9mb9yx757qsk6yib932449yc7yfqjh9h";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."redex-gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "treap" = self.lib.mkRacketDerivation rec {
  pname = "treap";
  src = fetchgit {
    name = "treap";
    url = "git://github.com/spencereir/treap.git";
    rev = "e703ae7f1bec7a7131eeb2e9e5e6b488c4b45d7e";
    sha256 = "0ai87bhaqclrck7fzabgyxgxd7iywhji1lnpl7v7c2ya0bi0b1mk";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "trivial" = self.lib.mkRacketDerivation rec {
  pname = "trivial";
  src = self.lib.extractPath {
    path = "trivial";
    src = fetchgit {
    name = "trivial";
    url = "git://github.com/bennn/trivial.git";
    rev = "c28c838d6d0116ba4c9d122c0e410ef178164e3a";
    sha256 = "1rrrcvl6yqs3k8hj8prw0q5dgbsiyznd8bc5bdmxbwz3j2gshb91";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."plot-lib" self."rackunit-lib" self."reprovide-lang" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."at-exp-lib" self."racket-doc" self."rackunit-abbrevs" self."rackunit-lib" self."scribble-doc" self."typed-racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "try" = self.lib.mkRacketDerivation rec {
  pname = "try";
  src = fetchgit {
    name = "try";
    url = "https://gitlab.com/RayRacine/try.git";
    rev = "b73f3053ac6930443bbbc6a12cfd947e1b4d9413";
    sha256 = "1vay9kr20fwj2sdb1xixrl38byp1gg9wcgn94wmvwvzf1v6pyg5a";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."base" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "try-racket-client" = self.lib.mkRacketDerivation rec {
  pname = "try-racket-client";
  src = fetchgit {
    name = "try-racket-client";
    url = "git://github.com/Bogdanp/try-racket-client.git";
    rev = "2ddd062b62284a7549f63bbedd8f6c4aa5c613b5";
    sha256 = "0cc959dc35zjbfa3z5gbdvq0ylkam1j4gs731g7qgl5djj6xpwpk";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ts-files" = self.lib.mkRacketDerivation rec {
  pname = "ts-files";
  src = fetchgit {
    name = "ts-files";
    url = "git://github.com/thoughtstem/ts-files.git";
    rev = "3252c883500641609200b698b73a09f0c96a6042";
    sha256 = "1hid3m5fkmb2bzv0hmikf4189jvpfdz1jj34v2rl6445yaicjh4f";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tulip" = self.lib.mkRacketDerivation rec {
  pname = "tulip";
  src = self.lib.extractPath {
    path = "tulip";
    src = fetchgit {
    name = "tulip";
    url = "git://github.com/lexi-lambda/racket-tulip.git";
    rev = "1613cfd4d7e8dbc8ceb86cf33479375147f42b2f";
    sha256 = "1lzj7skc9b78cj2k2scp5ydxdgympbrj9jh9w10nld4fycba3rc1";
  };
  };
  racketThinBuildInputs = [ self."base" self."tulip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tulip-lib" = self.lib.mkRacketDerivation rec {
  pname = "tulip-lib";
  src = self.lib.extractPath {
    path = "tulip-lib";
    src = fetchgit {
    name = "tulip-lib";
    url = "git://github.com/lexi-lambda/racket-tulip.git";
    rev = "1613cfd4d7e8dbc8ceb86cf33479375147f42b2f";
    sha256 = "1lzj7skc9b78cj2k2scp5ydxdgympbrj9jh9w10nld4fycba3rc1";
  };
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" self."megaparsack-lib" self."megaparsack-parser-tools" self."parser-tools-lib" self."curly-fn" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tulip-test" = self.lib.mkRacketDerivation rec {
  pname = "tulip-test";
  src = self.lib.extractPath {
    path = "tulip-test";
    src = fetchgit {
    name = "tulip-test";
    url = "git://github.com/lexi-lambda/racket-tulip.git";
    rev = "1613cfd4d7e8dbc8ceb86cf33479375147f42b2f";
    sha256 = "1lzj7skc9b78cj2k2scp5ydxdgympbrj9jh9w10nld4fycba3rc1";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."tulip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turn-based-game" = self.lib.mkRacketDerivation rec {
  pname = "turn-based-game";
  src = fetchgit {
    name = "turn-based-game";
    url = "git://github.com/AlexKnauth/turn-based-game.git";
    rev = "bdc793d50f67bb59446caecc9e5771d84e1eba17";
    sha256 = "1j1nc26pghd5lp8yi7sxh1mmjhz1dir1s9k41zzn2kqjdca31r41";
  };
  racketThinBuildInputs = [ self."base" self."agile" self."collections-lib" self."htdp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."htdp-doc" self."collections-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turnstile" = self.lib.mkRacketDerivation rec {
  pname = "turnstile";
  src = self.lib.extractPath {
    path = "turnstile";
    src = fetchgit {
    name = "turnstile";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."turnstile-lib" self."turnstile-example" self."turnstile-doc" self."turnstile-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turnstile-doc" = self.lib.mkRacketDerivation rec {
  pname = "turnstile-doc";
  src = self.lib.extractPath {
    path = "turnstile-doc";
    src = fetchgit {
    name = "turnstile-doc";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."sandbox-lib" self."scribble-lib" self."rackunit-lib" self."rackunit-doc" self."rackunit-macrotypes-lib" self."turnstile-lib" self."turnstile-example" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turnstile-example" = self.lib.mkRacketDerivation rec {
  pname = "turnstile-example";
  src = self.lib.extractPath {
    path = "turnstile-example";
    src = fetchgit {
    name = "turnstile-example";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."turnstile-lib" self."macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turnstile-lib" = self.lib.mkRacketDerivation rec {
  pname = "turnstile-lib";
  src = self.lib.extractPath {
    path = "turnstile-lib";
    src = fetchgit {
    name = "turnstile-lib";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."macrotypes-lib" self."lens-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "turnstile-test" = self.lib.mkRacketDerivation rec {
  pname = "turnstile-test";
  src = self.lib.extractPath {
    path = "turnstile-test";
    src = fetchgit {
    name = "turnstile-test";
    url = "git://github.com/stchang/macrotypes.git";
    rev = "4215bf245fa3f05c12808e5ceee69422bbebcd5e";
    sha256 = "1bfawmasdpc79ag1hjvwlwdv94lbrxjffx42jxmr1h053vqsbfda";
  };
  };
  racketThinBuildInputs = [ self."base" self."turnstile-example" self."rackunit-macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tweedledee" = self.lib.mkRacketDerivation rec {
  pname = "tweedledee";
  src = fetchgit {
    name = "tweedledee";
    url = "git://github.com/zyrolasting/tweedledee.git";
    rev = "f0919e3816b448cea75db7d9121f355a9fe4edec";
    sha256 = "13fja017yrpzdqhfrcilrzwc0myrg6qv2x6rhk3nxd4720ky7f5d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tweedledum" = self.lib.mkRacketDerivation rec {
  pname = "tweedledum";
  src = fetchgit {
    name = "tweedledum";
    url = "git://github.com/zyrolasting/tweedledum.git";
    rev = "64417ba609ea7a5db1ca7c25baa63dfb59a3955e";
    sha256 = "0lcnsf0cr120mj16nbmyrkydavfml58vpmciyd1mh9sfg3hdjl37";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "twilio" = self.lib.mkRacketDerivation rec {
  pname = "twilio";
  src = self.lib.extractPath {
    path = "twilio";
    src = fetchgit {
    name = "twilio";
    url = "git://github.com/Bogdanp/racket-twilio.git";
    rev = "2c4cb087cd4d6b9eb6bc6a57035169e32848629e";
    sha256 = "0id12b3n06pbc85s77s81idf12ni25nx38s3z3rraswc15bjb01p";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "twixt" = self.lib.mkRacketDerivation rec {
  pname = "twixt";
  src = fetchgit {
    name = "twixt";
    url = "git://github.com/jackfirth/twixt.git";
    rev = "41aca88a7a7e5a993460df011da67b4fa31daadc";
    sha256 = "12bjb8n4f9h9sprpj22w1zvsr90kzdvkqxffn7yzwa47x67wb7rf";
  };
  racketThinBuildInputs = [ self."pict-lib" self."rebellion" self."base" self."pict-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "txexpr" = self.lib.mkRacketDerivation rec {
  pname = "txexpr";
  src = fetchgit {
    name = "txexpr";
    url = "git://github.com/mbutterick/txexpr.git";
    rev = "c40f64292cf0444a90e4d8d0decbd0e01dfd6b62";
    sha256 = "08hq3wd7221bhg6l32jch5mcngmphywjdfx15hg78w5qxx4xz1df";
  };
  racketThinBuildInputs = [ self."base" self."sugar" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."rackunit-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "txexpr-stxparse" = self.lib.mkRacketDerivation rec {
  pname = "txexpr-stxparse";
  src = fetchgit {
    name = "txexpr-stxparse";
    url = "git://github.com/AlexKnauth/txexpr-stxparse.git";
    rev = "9cd7beea3ff8ecf1fd3e77cddf71c931f9fc24df";
    sha256 = "1h7fzg0a0k0ynm7pkbwa7lj0cq890q1akfrlbgwj7k2b0di0b3ap";
  };
  racketThinBuildInputs = [ self."base" self."txexpr" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "type-conventions" = self.lib.mkRacketDerivation rec {
  pname = "type-conventions";
  src = fetchgit {
    name = "type-conventions";
    url = "git://github.com/jackfirth/type-conventions.git";
    rev = "550d9045206bd1c0a05713fa866a9cc2a0b48d99";
    sha256 = "08rgqm9ydqmw5r05pgl61cil61pl0yfiyvd7g9yybnnaqb6k9ggz";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "type-expander" = self.lib.mkRacketDerivation rec {
  pname = "type-expander";
  src = fetchgit {
    name = "type-expander";
    url = "git://github.com/jsmaniac/type-expander.git";
    rev = "22f9c4511531719eac76a5fe94688cbfbcee8f0a";
    sha256 = "14wva97qizalqmmsrhpp5an6s475mmlf82f1csgj6rh6gh8s3i4z";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."hyper-literate" self."auto-syntax-e" self."debug-scopes" self."version-case" self."scribble-lib" self."racket-doc" self."typed-racket-more" self."typed-racket-doc" self."scribble-enhanced" self."mutable-match-lambda" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-map" = self.lib.mkRacketDerivation rec {
  pname = "typed-map";
  src = self.lib.extractPath {
    path = "typed-map";
    src = fetchgit {
    name = "typed-map";
    url = "git://github.com/jsmaniac/typed-map.git";
    rev = "e61454db13bab1c7749745a62821ad0a17adc26f";
    sha256 = "06k7pcs5kzh6ihbl4qmcl1l7vb8nq1hbbvw13gmn5q5b7zxz5804";
  };
  };
  racketThinBuildInputs = [ self."typed-map-lib" self."typed-map-test" self."typed-map-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-map-doc" = self.lib.mkRacketDerivation rec {
  pname = "typed-map-doc";
  src = self.lib.extractPath {
    path = "typed-map-doc";
    src = fetchgit {
    name = "typed-map-doc";
    url = "git://github.com/jsmaniac/typed-map.git";
    rev = "e61454db13bab1c7749745a62821ad0a17adc26f";
    sha256 = "06k7pcs5kzh6ihbl4qmcl1l7vb8nq1hbbvw13gmn5q5b7zxz5804";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."aful" self."typed-map-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-map-lib" = self.lib.mkRacketDerivation rec {
  pname = "typed-map-lib";
  src = self.lib.extractPath {
    path = "typed-map-lib";
    src = fetchgit {
    name = "typed-map-lib";
    url = "git://github.com/jsmaniac/typed-map.git";
    rev = "e61454db13bab1c7749745a62821ad0a17adc26f";
    sha256 = "06k7pcs5kzh6ihbl4qmcl1l7vb8nq1hbbvw13gmn5q5b7zxz5804";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-map-test" = self.lib.mkRacketDerivation rec {
  pname = "typed-map-test";
  src = self.lib.extractPath {
    path = "typed-map-test";
    src = fetchgit {
    name = "typed-map-test";
    url = "git://github.com/jsmaniac/typed-map.git";
    rev = "e61454db13bab1c7749745a62821ad0a17adc26f";
    sha256 = "06k7pcs5kzh6ihbl4qmcl1l7vb8nq1hbbvw13gmn5q5b7zxz5804";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-map-lib" self."aful" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket.zip";
    sha1 = "9ac9d3895831bc38e2200b4e22d3cd27fb0c0f83";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-compatibility" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-compatibility";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket-compatibility.zip";
    sha1 = "edec0fde70a60e6c4c8fd35ecfd22c02c6a1a8ee";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."typed-racket-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-datatype" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-datatype";
  src = self.lib.extractPath {
    path = "typed-racket-datatype";
    src = fetchgit {
    name = "typed-racket-datatype";
    url = "git://github.com/AlexKnauth/typed-racket-datatype.git";
    rev = "4c9bd06b720d1e6f66b941951c6b33341bdb5c49";
    sha256 = "0yks5axk3jydi66f3svg2zhj9dbbiqgvif110vldgk47464a42iq";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-datatype-lib" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."rackunit-lib" self."rackunit-typed" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-datatype-lib" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-datatype-lib";
  src = self.lib.extractPath {
    path = "typed-racket-datatype-lib";
    src = fetchgit {
    name = "typed-racket-datatype-lib";
    url = "git://github.com/AlexKnauth/typed-racket-datatype.git";
    rev = "4c9bd06b720d1e6f66b941951c6b33341bdb5c49";
    sha256 = "0yks5axk3jydi66f3svg2zhj9dbbiqgvif110vldgk47464a42iq";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-doc" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket-doc.zip";
    sha1 = "54f6118e9c07c174c4c53b00891e348723cf627b";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."srfi-lite-lib" self."r6rs-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."pict-lib" self."typed-racket-lib" self."typed-racket-compatibility" self."typed-racket-more" self."draw-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-hacks" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-hacks";
  src = self.lib.extractPath {
    path = "typed-racket-hacks";
    src = fetchgit {
    name = "typed-racket-hacks";
    url = "git://github.com/philnguyen/typed-racket-hacks.git";
    rev = "6d462852a29abb4406d53db2587e9d463b90b2ae";
    sha256 = "1y11mcz90y2m3wpx3sr3z7av0b6b9sxjqkiwm9vdpmb5kh6k4bzy";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."set-extras" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-lib" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket-lib.zip";
    sha1 = "37d9a0169389450db5fa0df89c3a98297c72ae46";
  };
  racketThinBuildInputs = [ self."base" self."source-syntax" self."pconvert-lib" self."compatibility-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-more" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-more";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket-more.zip";
    sha1 = "8bcfb5f9ae3d01128ccfdd6c9d35445e9e0c661c";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."net-lib" self."net-cookies-lib" self."web-server-lib" self."db-lib" self."draw-lib" self."rackunit-lib" self."rackunit-gui" self."rackunit-typed" self."snip-lib" self."typed-racket-lib" self."gui-lib" self."pict-lib" self."images-lib" self."racket-index" self."sandbox-lib" self."pconvert-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-stream" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-stream";
  src = fetchgit {
    name = "typed-racket-stream";
    url = "git://github.com/AlexKnauth/typed-racket-stream.git";
    rev = "74b0dcf6787d23ef50977134a5d232674e35adf0";
    sha256 = "1hi15nhfdgaqbllniwbhspj8dwqqx6fgxr0cw7p0ypdly9pfhw0b";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-test" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/typed-racket-test.zip";
    sha1 = "65ee7a4c961914d635ee57f8b98c043898d2dac3";
  };
  racketThinBuildInputs = [ self."redex-lib" self."sandbox-lib" self."base" self."typed-racket-lib" self."typed-racket-more" self."typed-racket-compatibility" self."2d" self."rackunit-lib" self."racket-index" self."compatibility-lib" self."math-lib" self."racket-test-core" self."scheme-lib" self."base" self."racket-benchmarks" self."rackunit-lib" self."compiler-lib" self."redex-lib" self."htdp-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-rosette" = self.lib.mkRacketDerivation rec {
  pname = "typed-rosette";
  src = fetchgit {
    name = "typed-rosette";
    url = "git://github.com/stchang/typed-rosette.git";
    rev = "d72d4e7aad2c339fdd49c70682d56f83ab3eae3d";
    sha256 = "0nav2rs3a4hpad9f5ccib4mhwh9fwix0rwi9hqg8ipx4ilcqs30a";
  };
  racketThinBuildInputs = [ self."base" self."rosette" self."turnstile" self."rackunit-lib" self."lens-common" self."lens-unstable" self."syntax-classes-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-stack" = self.lib.mkRacketDerivation rec {
  pname = "typed-stack";
  src = fetchgit {
    name = "typed-stack";
    url = "git://github.com/lehitoskin/typed-stack.git";
    rev = "f6e63310ea20e147f9fbb80e5fb9768b6905f7aa";
    sha256 = "17wy3h04ndz86s8ka7csf4v2ni8sjcvfbwyxc2k1j1dnnv510m7a";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-more" self."typed-racket-lib" self."scribble-lib" self."typed-racket-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-struct-props" = self.lib.mkRacketDerivation rec {
  pname = "typed-struct-props";
  src = fetchgit {
    name = "typed-struct-props";
    url = "git://github.com/jsmaniac/typed-struct-props.git";
    rev = "6030806eec0377936ce24745c3c44b52f567b3ec";
    sha256 = "19b14ya4d8b1iy7dhgbpl3avmqd7jiiz9i32kwkm2lls88zk9zd1";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."type-expander" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-worklist" = self.lib.mkRacketDerivation rec {
  pname = "typed-worklist";
  src = fetchgit {
    name = "typed-worklist";
    url = "git://github.com/jsmaniac/typed-worklist.git";
    rev = "976b85d9c6c7956184e0c3843a15bc727173719c";
    sha256 = "18c59ff2n2mmnyjn1s24i01nc9ws6mrxcyygxzisnnmbl8ff1w58";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."type-expander" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typeset-rewriter" = self.lib.mkRacketDerivation rec {
  pname = "typeset-rewriter";
  src = fetchgit {
    name = "typeset-rewriter";
    url = "git://github.com/pnwamk/typeset-rewriter";
    rev = "9737f385b57a74564221ebd719c01f4180fbf6f8";
    sha256 = "13zzdpr913whkhzrq4qrniv6h6l09r7fyh264nj5b5l1j2j5jqha";
  };
  racketThinBuildInputs = [ self."base" self."redex-pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tzdata" = self.lib.mkRacketDerivation rec {
  pname = "tzdata";
  src = fetchgit {
    name = "tzdata";
    url = "git://github.com/97jaz/tzdata.git";
    rev = "338c6730c1d0ff9fb0761324cd21de242a1d136a";
    sha256 = "15rvqn2zgczxfig1sj0kpcs0pfll4vs2i386hrkd7xn91nc0irrr";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tzgeolookup" = self.lib.mkRacketDerivation rec {
  pname = "tzgeolookup";
  src = fetchgit {
    name = "tzgeolookup";
    url = "git://github.com/alex-hhh/tzgeolookup.git";
    rev = "93abcae2b9ab1b77004cf65fbdc0a291680bc734";
    sha256 = "0b7w64691m2jgyspyw0cn6y60q23cixjkclwxh6lccmjz864xidz";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tzinfo" = self.lib.mkRacketDerivation rec {
  pname = "tzinfo";
  src = fetchgit {
    name = "tzinfo";
    url = "git://github.com/97jaz/tzinfo.git";
    rev = "09f4d80c1871031ba359736807125cd3e7c15207";
    sha256 = "1lmixmyabyz8531f4am7jl7y6ghdqd4mi3k46fmaz0abblbjrqv9";
  };
  racketThinBuildInputs = [ self."base" self."cldr-core" self."rackunit-lib" self."tzdata" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "udelim" = self.lib.mkRacketDerivation rec {
  pname = "udelim";
  src = fetchgit {
    name = "udelim";
    url = "git://github.com/willghatch/racket-udelim.git";
    rev = "0952a8263c8e6cf1e7cd60e2daed62008246f25e";
    sha256 = "1wp0maw0b8qj6dwgpgf9mhqj3dgz5pnsrwimx1ar1w3rzbgrxd4n";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."sandbox-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "udev" = self.lib.mkRacketDerivation rec {
  pname = "udev";
  src = fetchgit {
    name = "udev";
    url = "git://github.com/mordae/racket-udev.git";
    rev = "de2cbf3f9b3fb754aecce1bf5ee64811e1700c5b";
    sha256 = "0jvr47r66l3qbn2dmkrw10pi7wzd6np7y85sa1md7frg9s187wvx";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ulid" = self.lib.mkRacketDerivation rec {
  pname = "ulid";
  src = fetchgit {
    name = "ulid";
    url = "git://github.com/Bogdanp/racket-ulid.git";
    rev = "2fb3dbaca00f276ac78bf93f1892140fdc60ee9a";
    sha256 = "1kfb53csls3f7yayljznwny7z3wzpj147sgw3qiqcvvqak2i5y83";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackcheck" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unb-cs3613" = self.lib.mkRacketDerivation rec {
  pname = "unb-cs3613";
  src = fetchgit {
    name = "unb-cs3613";
    url = "https://pivot.cs.unb.ca/git/unb-cs3613.git";
    rev = "f8242231a081264392f731e949356fa08eab0cbf";
    sha256 = "04p0fr9s0h47gxniv82dl5pyqj4ddj89g9129xyylc477s30zl8v";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."plait" self."brag" self."plai-dynamic" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unicode-properties" = self.lib.mkRacketDerivation rec {
  pname = "unicode-properties";
  src = fetchgit {
    name = "unicode-properties";
    url = "git://github.com/jbclements/unicode-props.git";
    rev = "c72c6c7678e44257bde7a8a4973196b064a9237f";
    sha256 = "1680a8wyw9y7zbk0zbxr7axw7fkh9zb719iy0p4jzy8q5p54f30x";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unified-for" = self.lib.mkRacketDerivation rec {
  pname = "unified-for";
  src = fetchgit {
    name = "unified-for";
    url = "git://github.com/michaelmmacleod/unified-for.git";
    rev = "9b0e47c753dbd218b79519e101d48fe3c323497a";
    sha256 = "0n67yhhm502fx45p7jdxid6xs0aa0n1b5nb090fmajl6kfdd1vm3";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."expect" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-signals" = self.lib.mkRacketDerivation rec {
  pname = "unix-signals";
  src = fetchgit {
    name = "unix-signals";
    url = "git://github.com/tonyg/racket-unix-signals.git";
    rev = "7231d17617a013da8f0b057f479f3c189d56daf6";
    sha256 = "03yy3dq1rnibsg1xg7c6cjpk37d7rnrrk0ipbvrwx8s3r6hdvai2";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."make" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/unix-socket.zip";
    sha1 = "15d9236ba245ae0e6cf0de066c12eedf15a325ab";
  };
  racketThinBuildInputs = [ self."unix-socket-lib" self."unix-socket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-doc" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/unix-socket-doc.zip";
    sha1 = "b07f179359bc1d65a38bbb583b9897a315f26791";
  };
  racketThinBuildInputs = [ self."base" self."unix-socket-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-lib" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/unix-socket-lib.zip";
    sha1 = "ecb512e3c8f639fc8e5e25add7a12296e60ae1cb";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-test" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/unix-socket-test.zip";
    sha1 = "0aa350858ae44f5e4ad725db3db1862cf15f3575";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."unix-socket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unreachable" = self.lib.mkRacketDerivation rec {
  pname = "unreachable";
  src = self.lib.extractPath {
    path = "unreachable";
    src = fetchgit {
    name = "unreachable";
    url = "git://github.com/philnguyen/unreachable.git";
    rev = "a7d303d673ebb887ed49550ee27da307948cda37";
    sha256 = "0wdax75gbysr94vlz0g7s54svf4a5ixh14l2hjb7z5y2z7gj74ky";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable" = self.lib.mkRacketDerivation rec {
  pname = "unstable";
  src = self.lib.extractPath {
    path = "unstable";
    src = fetchgit {
    name = "unstable";
    url = "git://github.com/racket/unstable.git";
    rev = "99149bf1a6a82b2309cc04e363a87ed36972b64b";
    sha256 = "0as2a0np8mb3hilb0h4plyw42203kczpbpfyl71ljwnf7z5vg9mh";
  };
  };
  racketThinBuildInputs = [ self."unstable-lib" self."unstable-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-2d" = self.lib.mkRacketDerivation rec {
  pname = "unstable-2d";
  src = fetchgit {
    name = "unstable-2d";
    url = "git://github.com/racket/unstable-2d.git";
    rev = "b623df87d732171833103e05b3e76d3ce79f1047";
    sha256 = "1kpl8kvh8y1vsfn1bz69vhpafj82d9vnc9sd13p5ch5w1cvh82bi";
  };
  racketThinBuildInputs = [ self."base" self."2d-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-contract-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-contract-lib";
  src = fetchgit {
    name = "unstable-contract-lib";
    url = "git://github.com/racket/unstable-contract-lib.git";
    rev = "198b743c39450f0340dc03a792c29794652d6e08";
    sha256 = "0ypbb8m5cmljrkkhxjawkyp36shsdwx78sm22yyhn0p8xpz0zsv2";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-debug-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-debug-lib";
  src = fetchgit {
    name = "unstable-debug-lib";
    url = "git://github.com/racket/unstable-debug-lib.git";
    rev = "1511a2410d11a69b9116c5d6668869765ef58f56";
    sha256 = "0vq45cmchlhf5mwnzry7ic8infkdd95072cwwjwywqaxn0zi8dv9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-doc" = self.lib.mkRacketDerivation rec {
  pname = "unstable-doc";
  src = self.lib.extractPath {
    path = "unstable-doc";
    src = fetchgit {
    name = "unstable-doc";
    url = "git://github.com/racket/unstable.git";
    rev = "99149bf1a6a82b2309cc04e363a87ed36972b64b";
    sha256 = "0as2a0np8mb3hilb0h4plyw42203kczpbpfyl71ljwnf7z5vg9mh";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-doc" self."scheme-lib" self."at-exp-lib" self."compatibility-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."slideshow-lib" self."typed-racket-lib" self."unstable-contract-lib" self."unstable-debug-lib" self."unstable-lib" self."unstable-list-lib" self."unstable-macro-testing-lib" self."unstable-options-lib" self."unstable-parameter-group-lib" self."unstable-pretty-lib" self."unstable-2d" self."draw-doc" self."gui-doc" self."pict-doc" self."scribble-doc" self."slideshow-doc" self."class-iop-doc" self."automata-doc" self."markparam-doc" self."temp-c-doc" self."unix-socket-doc" self."2d-doc" self."option-contract-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-flonum-doc" = self.lib.mkRacketDerivation rec {
  pname = "unstable-flonum-doc";
  src = self.lib.extractPath {
    path = "unstable-flonum-doc";
    src = fetchgit {
    name = "unstable-flonum-doc";
    url = "git://github.com/racket/unstable-flonum.git";
    rev = "e7e1ed3e9c2f3448e1eac2084e2f2f6c4d126000";
    sha256 = "1drb7kwmkq38ib948q0hdnwfzwzhwpqb8q9jn920avb6jxw7wjzm";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."unstable" self."unstable-flonum-lib" self."plot" self."math-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-flonum-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-flonum-lib";
  src = self.lib.extractPath {
    path = "unstable-flonum-lib";
    src = fetchgit {
    name = "unstable-flonum-lib";
    url = "git://github.com/racket/unstable-flonum.git";
    rev = "e7e1ed3e9c2f3448e1eac2084e2f2f6c4d126000";
    sha256 = "1drb7kwmkq38ib948q0hdnwfzwzhwpqb8q9jn920avb6jxw7wjzm";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-latent-contract-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-latent-contract-lib";
  src = fetchgit {
    name = "unstable-latent-contract-lib";
    url = "git://github.com/racket/unstable-latent-contract-lib.git";
    rev = "9df3d23294e7ae9ac06fe613c383e1f04e56f3ae";
    sha256 = "01p10yasqha0wkpr2dp7hbd7miym5gcp5ymx79jig8qb1y95jih4";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."images-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-lib";
  src = self.lib.extractPath {
    path = "unstable-lib";
    src = fetchgit {
    name = "unstable-lib";
    url = "git://github.com/racket/unstable.git";
    rev = "99149bf1a6a82b2309cc04e363a87ed36972b64b";
    sha256 = "0as2a0np8mb3hilb0h4plyw42203kczpbpfyl71ljwnf7z5vg9mh";
  };
  };
  racketThinBuildInputs = [ self."automata-lib" self."base" self."draw-lib" self."gui-lib" self."markparam-lib" self."pict-lib" self."ppict" self."scribble-lib" self."slideshow-lib" self."temp-c-lib" self."unstable-macro-testing-lib" self."unix-socket-lib" self."staged-slide" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-list-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-list-lib";
  src = fetchgit {
    name = "unstable-list-lib";
    url = "git://github.com/racket/unstable-list-lib.git";
    rev = "0b3e390a25d5347c3e3b6e08b605b2865f0fae10";
    sha256 = "1108hsfady5k0nih04lvy6f9hpfksliylzymxkm5wqmr2bychdlc";
  };
  racketThinBuildInputs = [ self."base" self."class-iop-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-macro-testing-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-macro-testing-lib";
  src = fetchgit {
    name = "unstable-macro-testing-lib";
    url = "git://github.com/racket/unstable-macro-testing-lib.git";
    rev = "65b4dcc6d6d4aa6a1a29cb3fc039fb4a06968a45";
    sha256 = "1dv1k4y0p2aqqxs4kb90nb3kvsc8rnk2b6f96xzp9cv7ixfrxj5q";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-options-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-options-lib";
  src = fetchgit {
    name = "unstable-options-lib";
    url = "git://github.com/racket/unstable-options-lib.git";
    rev = "5b9ff5e62319ddb929235c5ddcd4cee350ee9a9b";
    sha256 = "1w4maabqnpcgm9q14n7j8anc4yj8w9c1lnyd0pkbwrf7pxsj18q8";
  };
  racketThinBuildInputs = [ self."base" self."option-contract-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-parameter-group-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-parameter-group-lib";
  src = fetchgit {
    name = "unstable-parameter-group-lib";
    url = "git://github.com/racket/unstable-parameter-group-lib.git";
    rev = "1906272f807c12a3d7e2a1c430c5b5745c2de6a4";
    sha256 = "0j3zxrj909ycpa9p14rw5yn7cmm6096n7wh7hqysvlmrmph3vjww";
  };
  racketThinBuildInputs = [ self."base" self."images-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-pretty-lib" = self.lib.mkRacketDerivation rec {
  pname = "unstable-pretty-lib";
  src = fetchgit {
    name = "unstable-pretty-lib";
    url = "git://github.com/racket/unstable-pretty-lib.git";
    rev = "d420f822301174b1931c8b43d2131924fc75565f";
    sha256 = "0xyzf76da9bz9i78h2lnlxxvc5iqx6v192h23xmdprpxi3zb10b9";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-redex" = self.lib.mkRacketDerivation rec {
  pname = "unstable-redex";
  src = fetchgit {
    name = "unstable-redex";
    url = "git://github.com/racket/unstable-redex.git";
    rev = "c8fd60d300039f1d1a5de82683746223945d651c";
    sha256 = "00m8ynpqlr8xr952w6nbaf8sy2bcq6zq6f555ka3xm4fh1xnk1zs";
  };
  racketThinBuildInputs = [ self."base" self."pict-lib" self."redex-lib" self."redex-pict-lib" self."scribble-lib" self."pict-doc" self."redex-doc" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unstable-test" = self.lib.mkRacketDerivation rec {
  pname = "unstable-test";
  src = self.lib.extractPath {
    path = "unstable-test";
    src = fetchgit {
    name = "unstable-test";
    url = "git://github.com/racket/unstable.git";
    rev = "99149bf1a6a82b2309cc04e363a87ed36972b64b";
    sha256 = "0as2a0np8mb3hilb0h4plyw42203kczpbpfyl71ljwnf7z5vg9mh";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."scheme-lib" self."at-exp-lib" self."compatibility-lib" self."eli-tester" self."gui-lib" self."planet-lib" self."racket-test" self."rackunit-lib" self."srfi-lib" self."syntax-color-lib" self."typed-racket-lib" self."unstable-contract-lib" self."unstable-debug-lib" self."unstable-lib" self."unstable-list-lib" self."unstable-options-lib" self."unstable-parameter-group-lib" self."unstable-2d" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uri" = self.lib.mkRacketDerivation rec {
  pname = "uri";
  src = fetchgit {
    name = "uri";
    url = "https://gitlab.com/RayRacine/uri.git";
    rev = "79934c1432baad34a3272c0429caa4b695c4b996";
    sha256 = "1mrlb77hcw1z0k5mnchjyllpg20rjg9ffww5rjqlpwsrpng6x9hr";
  };
  racketThinBuildInputs = [ self."string-util" self."opt" self."typed-racket-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uri-old" = self.lib.mkRacketDerivation rec {
  pname = "uri-old";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/uri-old.zip";
    sha1 = "27851ba27c8bf7770d2c308d403a85d179bc62b1";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."overeasy" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uri-template" = self.lib.mkRacketDerivation rec {
  pname = "uri-template";
  src = fetchgit {
    name = "uri-template";
    url = "git://github.com/jessealama/uri-template.git";
    rev = "6fe4420e3a55da6ae02df453a142b96ef3b3b4ea";
    sha256 = "0zigbpscb0ly1dqh9q8dv9cp4ldx744fvh1lrralj44f2yif9m3f";
  };
  racketThinBuildInputs = [ self."base" self."brag" self."beautiful-racket-lib" self."br-parser-tools-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "urlang" = self.lib.mkRacketDerivation rec {
  pname = "urlang";
  src = fetchgit {
    name = "urlang";
    url = "git://github.com/soegaard/urlang.git";
    rev = "4c227edd5c446480474eb5ae0a462cd6c015b6dd";
    sha256 = "1rc6x6kf4395ixcqczw4p7s74csw757sncpx6n3hlhz2m6papmya";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."html-writing" self."nanopass" self."net-lib" self."rackunit-lib" self."scribble-html-lib" self."scribble-text-lib" self."srfi-lite-lib" self."web-server-lib" self."base" self."nanopass" self."at-exp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."html-writing" self."html-parsing" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uu-cs3520" = self.lib.mkRacketDerivation rec {
  pname = "uu-cs3520";
  src = fetchgit {
    name = "uu-cs3520";
    url = "git://github.com/mflatt/uu-cs3520.git";
    rev = "b0dfad48eab5d41706b6016bdfc6b9acafe46093";
    sha256 = "0w1yqhsrf2f94klc3dw8x07hcr17ka911nxwd5yp7zc8hf8i23a9";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."plait" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uu-cs5510" = self.lib.mkRacketDerivation rec {
  pname = "uu-cs5510";
  src = fetchgit {
    name = "uu-cs5510";
    url = "git://github.com/mflatt/uu-cs5510.git";
    rev = "d6736f807b31f637e141ae97d28d65e8e10465aa";
    sha256 = "1rlx1z410260pp9546j0r3q1bbngi8hjawk07ll3wqkr7yanj56b";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."plai-typed" self."plai-typed-s-exp-match" self."plai-lazy" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "uuid" = self.lib.mkRacketDerivation rec {
  pname = "uuid";
  src = fetchgit {
    name = "uuid";
    url = "git://github.com/LiberalArtist/uuid.git";
    rev = "eda475cbe22f78e7054cb8b9203039c069d363fa";
    sha256 = "0kr1wz1vbal0gh1y3gsc0sm70wj5a5c0kq813h3fw7bahap4jaqi";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "values-plus" = self.lib.mkRacketDerivation rec {
  pname = "values-plus";
  src = fetchgit {
    name = "values-plus";
    url = "git://github.com/mflatt/values-plus.git";
    rev = "75df2e111928317ff61e9b82c2aaac664ddd0d6b";
    sha256 = "1i0fn5bbkyl13gcim3dm9m8w5rv3fddjrkffza6lgcfrnmi8b4s8";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vector-struct" = self.lib.mkRacketDerivation rec {
  pname = "vector-struct";
  src = fetchgit {
    name = "vector-struct";
    url = "git://github.com/lexi-lambda/racket-vector-struct.git";
    rev = "f5137a445b567a213f20d9c35c60cea88f61c7b1";
    sha256 = "09bxjnv0722zpxny0mxi0w02m0kdyarqg5sxsrpjvmw2zzra88y4";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vela" = self.lib.mkRacketDerivation rec {
  pname = "vela";
  src = self.lib.extractPath {
    path = "vela";
    src = fetchgit {
    name = "vela";
    url = "git://github.com/nuty/vela.git";
    rev = "5998a2cf7101a9b98d91fce11c4c1d86f0f5a274";
    sha256 = "03j7xr7yb4ki7zfjvqd2gkhzn4bckvpsi86c8x3ka8sp45r8qyzw";
  };
  };
  racketThinBuildInputs = [ self."base" self."vela-lib" self."vela-docs" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vela-docs" = self.lib.mkRacketDerivation rec {
  pname = "vela-docs";
  src = self.lib.extractPath {
    path = "vela-doc";
    src = fetchgit {
    name = "vela-docs";
    url = "git://github.com/nuty/vela.git";
    rev = "5998a2cf7101a9b98d91fce11c4c1d86f0f5a274";
    sha256 = "03j7xr7yb4ki7zfjvqd2gkhzn4bckvpsi86c8x3ka8sp45r8qyzw";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."racket-doc" self."data-doc" self."data-lib" self."vela-lib" self."scribble-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vela-lib" = self.lib.mkRacketDerivation rec {
  pname = "vela-lib";
  src = self.lib.extractPath {
    path = "vela-lib";
    src = fetchgit {
    name = "vela-lib";
    url = "git://github.com/nuty/vela.git";
    rev = "5998a2cf7101a9b98d91fce11c4c1d86f0f5a274";
    sha256 = "03j7xr7yb4ki7zfjvqd2gkhzn4bckvpsi86c8x3ka8sp45r8qyzw";
  };
  };
  racketThinBuildInputs = [ self."web-server" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "version-case" = self.lib.mkRacketDerivation rec {
  pname = "version-case";
  src = fetchgit {
    name = "version-case";
    url = "git://github.com/samth/version-case.git";
    rev = "da496dc183325d9dd3bebcdf2e2813d7ee5e87c9";
    sha256 = "037acnpqljcbhij3nkhabf67as94sfnmf6sk69g8nw1bn8a1qb9y";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."drracket-plugin-lib" self."gui-lib" self."scheme-lib" self."srfi-lib" self."srfi-lite-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video" = self.lib.mkRacketDerivation rec {
  pname = "video";
  src = fetchgit {
    name = "video";
    url = "git://github.com/videolang/video";
    rev = "aa958b5ab250c8a202b24444935255d773608ea6";
    sha256 = "0gp86xk7wrcvb96fl2lsi3r1x9i18kqnvn3cygsnpdqfpq0g0hbc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."draw-lib" self."images-lib" self."drracket-plugin-lib" self."data-lib" self."pict-lib" self."wxme-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."bitsyntax" self."opengl" self."portaudio" self."net-lib" self."syntax-color-lib" self."parser-tools-lib" self."graph" self."libvid-x86_64-macosx" self."libvid-x86_64-win32" self."libvid-i386-win32" self."libvid-x86_64-linux" self."libvid-i386-linux" self."ffmpeg-x86_64-macosx-3-4" self."ffmpeg-x86_64-win32-3-4" self."ffmpeg-i386-win32-3-4" self."scribble-lib" self."racket-doc" self."gui-doc" self."draw-doc" self."ppict" self."reprovide-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-samples" = self.lib.mkRacketDerivation rec {
  pname = "video-samples";
  src = fetchgit {
    name = "video-samples";
    url = "git://github.com/videolang/test-samples.git";
    rev = "6ac1cfc77152350d1ce55738447350ae0d43cf5d";
    sha256 = "09szmqpbi4daiwwp9jqa0sjj636hgn61lddpiil47542wz23m8ys";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."video" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-testing" = self.lib.mkRacketDerivation rec {
  pname = "video-testing";
  src = fetchgit {
    name = "video-testing";
    url = "git://github.com/videolang/video";
    rev = "aa958b5ab250c8a202b24444935255d773608ea6";
    sha256 = "0gp86xk7wrcvb96fl2lsi3r1x9i18kqnvn3cygsnpdqfpq0g0hbc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."draw-lib" self."images-lib" self."drracket-plugin-lib" self."data-lib" self."pict-lib" self."wxme-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."bitsyntax" self."opengl" self."portaudio" self."net-lib" self."syntax-color-lib" self."parser-tools-lib" self."graph" self."libvid-x86_64-macosx" self."libvid-x86_64-win32" self."libvid-i386-win32" self."libvid-x86_64-linux" self."libvid-i386-linux" self."ffmpeg-x86_64-macosx-3-4" self."ffmpeg-x86_64-win32-3-4" self."ffmpeg-i386-win32-3-4" self."scribble-lib" self."racket-doc" self."gui-doc" self."draw-doc" self."ppict" self."reprovide-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-unstable" = self.lib.mkRacketDerivation rec {
  pname = "video-unstable";
  src = fetchgit {
    name = "video-unstable";
    url = "git://github.com/videolang/video.git";
    rev = "3c69669063c56ff8d269768589cb9506a33315e5";
    sha256 = "17lysqgd4h0kdx73vzmsdqc6ip5rlk56hss3880yapvic14lf5dy";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."draw-lib" self."images-lib" self."drracket-plugin-lib" self."data-lib" self."pict-lib" self."wxme-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."bitsyntax" self."opengl" self."portaudio" self."net-lib" self."syntax-color-lib" self."parser-tools-lib" self."graph" self."libvid-x86_64-macosx" self."libvid-x86_64-win32" self."libvid-i386-win32" self."libvid-x86_64-linux" self."libvid-i386-linux" self."ffmpeg-x86_64-macosx-3-4" self."ffmpeg-x86_64-win32-3-4" self."ffmpeg-i386-win32-3-4" self."scribble-lib" self."racket-doc" self."gui-doc" self."draw-doc" self."ppict" self."reprovide-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-v0-0" = self.lib.mkRacketDerivation rec {
  pname = "video-v0-0";
  src = fetchgit {
    name = "video-v0-0";
    url = "git://github.com/videolang/video";
    rev = "39112ec3b7fbc6b611a67cc5f9ac3c988c50f16d";
    sha256 = "1rnx43r7acx10395843dja64kvx1hd42y5s4qvvkhinsr8jb8558";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."images-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-v0-1" = self.lib.mkRacketDerivation rec {
  pname = "video-v0-1";
  src = fetchgit {
    name = "video-v0-1";
    url = "git://github.com/videolang/video";
    rev = "ca7db7f85ab7f19f91e1f63907c275fecdc39349";
    sha256 = "1l21ydyjdzvbn96329l7nvd8iv3iv6nmpbz9nqipp0q44s1g7g54";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."draw-lib" self."images-lib" self."drracket-plugin-lib" self."data-lib" self."pict-lib" self."wxme-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."bitsyntax" self."opengl" self."portaudio" self."ffi-definer-convention" self."scribble-lib" self."racket-doc" self."gui-doc" self."draw-doc" self."ppict" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "video-v0-2" = self.lib.mkRacketDerivation rec {
  pname = "video-v0-2";
  src = fetchgit {
    name = "video-v0-2";
    url = "git://github.com/videolang/video.git";
    rev = "8828d1c287030691cbc12f75fb803265fc3d97bb";
    sha256 = "061mhyx65g67713k106h9n5ih9galdfzl9kxxx2r38pyj5qsb99n";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."gui-lib" self."draw-lib" self."images-lib" self."drracket-plugin-lib" self."data-lib" self."pict-lib" self."wxme-lib" self."sandbox-lib" self."at-exp-lib" self."scribble-lib" self."bitsyntax" self."opengl" self."portaudio" self."net-lib" self."syntax-color-lib" self."parser-tools-lib" self."graph" self."libvid-x86_64-macosx-0-2" self."libvid-x86_64-win32-0-2" self."libvid-i386-win32-0-2" self."libvid-x86_64-linux-0-2" self."libvid-i386-linux-0-2" self."ffmpeg-x86_64-macosx-3-4" self."ffmpeg-x86_64-win32-3-4" self."ffmpeg-i386-win32-3-4" self."scribble-lib" self."racket-doc" self."gui-doc" self."draw-doc" self."ppict" self."reprovide-lang" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "virtual-mpu" = self.lib.mkRacketDerivation rec {
  pname = "virtual-mpu";
  src = fetchgit {
    name = "virtual-mpu";
    url = "git://github.com/euhmeuh/virtual-mpu.git";
    rev = "d8056f928a646bb9ac96fdb78cde794efc82d144";
    sha256 = "09gf2s5mf084j19dbfyz87vm0162nbhqfx92whw0wnbc8vwbis12";
  };
  racketThinBuildInputs = [ self."base" self."brag" self."br-parser-tools-lib" self."anaphoric" self."reprovide-lang" self."command-tree" self."rackunit-lib" self."charterm" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vlc" = self.lib.mkRacketDerivation rec {
  pname = "vlc";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/vlc.zip";
    sha1 = "e485bb6cef1936e0587f2115dd7d2c1cffd4c832";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."overeasy" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "voxel" = self.lib.mkRacketDerivation rec {
  pname = "voxel";
  src = fetchgit {
    name = "voxel";
    url = "git://github.com/dedbox/racket-voxel.git";
    rev = "9c23d1e8e71a80bac6e4251a517f70aef002ab9f";
    sha256 = "18xwqv4isihpca3a5kz8qwb4kw8cmkzp5cbj75sqwykp4bdzc1b4";
  };
  racketThinBuildInputs = [ self."base" self."opengl" self."glm" self."gui-lib" self."at-exp-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "vulkan" = self.lib.mkRacketDerivation rec {
  pname = "vulkan";
  src = fetchgit {
    name = "vulkan";
    url = "git://github.com/zyrolasting/racket-vulkan.git";
    rev = "046caef828b0854bc2a3c8d58221cb28799ea312";
    sha256 = "0vwgm49q71p0bhrxnk5f71rqg8psylikq2751hin7kw48y1qddkv";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."txexpr" self."graph-lib" self."draw-lib" self."natural-cli" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "w3s" = self.lib.mkRacketDerivation rec {
  pname = "w3s";
  src = fetchgit {
    name = "w3s";
    url = "git://github.com/wargrey/w3s.git";
    rev = "da3bdc748864c51660230247ff2370b3962ea590";
    sha256 = "0yhcw7jz8inrs2s25cagb9hw7lg2nkdhw73341q7s581pi09zn32";
  };
  racketThinBuildInputs = [ self."base" self."graphics" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "warp" = self.lib.mkRacketDerivation rec {
  pname = "warp";
  src = fetchgit {
    name = "warp";
    url = "git://github.com/david-vanderson/warp.git";
    rev = "cdc1d0bd942780fb5360dc6a34a2a06cf9518408";
    sha256 = "0la0cl1114sjdpahgkyjjn6waih582xy51arjc48rr99fsdhpg4l";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."mode-lambda" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wavelet-transform-haar-1d" = self.lib.mkRacketDerivation rec {
  pname = "wavelet-transform-haar-1d";
  src = fetchgit {
    name = "wavelet-transform-haar-1d";
    url = "git://github.com/jbclements/wavelet-transform-haar-1d.git";
    rev = "a24d96252701f80dbd382fb4a0dccaf2d19160b1";
    sha256 = "130gs0z7ibcd02dbrzvy0n5l4z8jl8ql8fbfvapvyqxkk4q1ww2h";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."plot-gui-lib" self."typed-racket-lib" self."typed-racket-more" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-galaxy" = self.lib.mkRacketDerivation rec {
  pname = "web-galaxy";
  src = self.lib.extractPath {
    path = "web-galaxy";
    src = fetchgit {
    name = "web-galaxy";
    url = "git://github.com/euhmeuh/web-galaxy.git";
    rev = "2d9d5710aec25d961dcfc37a2e88c3c0f435021f";
    sha256 = "0c4lchj8mn8vzsm0hbmw3r0wfglaw55ggf0x7id2p6zc0668d7b8";
  };
  };
  racketThinBuildInputs = [ self."web-galaxy-lib" self."web-galaxy-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-galaxy-doc" = self.lib.mkRacketDerivation rec {
  pname = "web-galaxy-doc";
  src = self.lib.extractPath {
    path = "web-galaxy-doc";
    src = fetchgit {
    name = "web-galaxy-doc";
    url = "git://github.com/euhmeuh/web-galaxy.git";
    rev = "2d9d5710aec25d961dcfc37a2e88c3c0f435021f";
    sha256 = "0c4lchj8mn8vzsm0hbmw3r0wfglaw55ggf0x7id2p6zc0668d7b8";
  };
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-galaxy-lib" = self.lib.mkRacketDerivation rec {
  pname = "web-galaxy-lib";
  src = self.lib.extractPath {
    path = "web-galaxy-lib";
    src = fetchgit {
    name = "web-galaxy-lib";
    url = "git://github.com/euhmeuh/web-galaxy.git";
    rev = "2d9d5710aec25d961dcfc37a2e88c3c0f435021f";
    sha256 = "0c4lchj8mn8vzsm0hbmw3r0wfglaw55ggf0x7id2p6zc0668d7b8";
  };
  };
  racketThinBuildInputs = [ self."base" self."anaphoric" self."web-server-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-galaxy-test" = self.lib.mkRacketDerivation rec {
  pname = "web-galaxy-test";
  src = self.lib.extractPath {
    path = "web-galaxy-test";
    src = fetchgit {
    name = "web-galaxy-test";
    url = "git://github.com/euhmeuh/web-galaxy.git";
    rev = "2d9d5710aec25d961dcfc37a2e88c3c0f435021f";
    sha256 = "0c4lchj8mn8vzsm0hbmw3r0wfglaw55ggf0x7id2p6zc0668d7b8";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."web-galaxy-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-io" = self.lib.mkRacketDerivation rec {
  pname = "web-io";
  src = fetchgit {
    name = "web-io";
    url = "git://github.com/mfelleisen/web-io.git";
    rev = "2225941f8ff49e1aa113c8dcacacfcf2b4a49b8a";
    sha256 = "1civ4mirhli08qncl8khg8gxxgq1wlv61nhhjybpl98sh39ig115";
  };
  racketThinBuildInputs = [ self."net-lib" self."htdp-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server" = self.lib.mkRacketDerivation rec {
  pname = "web-server";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/web-server.zip";
    sha1 = "3da7c4fb92b78b2681ef2f4f266592619f154972";
  };
  racketThinBuildInputs = [ self."web-server-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-doc" = self.lib.mkRacketDerivation rec {
  pname = "web-server-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/web-server-doc.zip";
    sha1 = "5d8ed7852cf18f0990e57871f8c9f5ab0df89624";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."compatibility-lib" self."db-lib" self."net-lib" self."net-cookies-lib" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."web-server-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-lib" = self.lib.mkRacketDerivation rec {
  pname = "web-server-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/web-server-lib.zip";
    sha1 = "7ef6348b7b2a74d09e8b2aa64d5ee0abdf2d2fda";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."net-lib" self."net-cookies-lib" self."compatibility-lib" self."scribble-text-lib" self."parser-tools-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-test" = self.lib.mkRacketDerivation rec {
  pname = "web-server-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/web-server-test.zip";
    sha1 = "404a8bb95f3c870588e585022c85015cc19e9b1d";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."eli-tester" self."htdp-lib" self."rackunit-lib" self."web-server-lib" self."net-cookies" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-sessions" = self.lib.mkRacketDerivation rec {
  pname = "web-sessions";
  src = fetchgit {
    name = "web-sessions";
    url = "https://bitbucket.org/nadeemabdulhamid/web-sessions.git";
    rev = "ba973ee46a41a81536ddf5d6a8ea8f928385b217";
    sha256 = "1nf9k7dlh1da840880lanivqmk12n5idxsxl9940hg5dawysi6g8";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "webapi" = self.lib.mkRacketDerivation rec {
  pname = "webapi";
  src = fetchgit {
    name = "webapi";
    url = "git://github.com/rmculpepper/webapi";
    rev = "c1a172e360db667be49dcd81eba85f4a35b73a94";
    sha256 = "0sxib8fpahn8is4p121a0mwm4dkk6qy8w11fw5wvxfbywll46hcq";
  };
  racketThinBuildInputs = [ self."base" self."sxml" self."html-writing" self."compatibility-lib" self."web-server-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "webscraperhelper" = self.lib.mkRacketDerivation rec {
  pname = "webscraperhelper";
  src = fetchurl {
    url = "http://www.neilvandyke.org/racket/webscraperhelper.zip";
    sha1 = "0cc7cf1c6ea962ad03fcf18f9b3230090725f175";
  };
  racketThinBuildInputs = [ self."base" self."mcfly" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wffi" = self.lib.mkRacketDerivation rec {
  pname = "wffi";
  src = fetchgit {
    name = "wffi";
    url = "git://github.com/greghendershott/wffi.git";
    rev = "03bd59bea2aa6e0a855de28fb5bb18769ed04b3b";
    sha256 = "0rblpn1q74znb0a17danjjb7j6zqyx13ql4qljhmb5qga7mh0wl2";
  };
  racketThinBuildInputs = [ self."base" self."http" self."parser-tools-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "whalesong" = self.lib.mkRacketDerivation rec {
  pname = "whalesong";
  src = fetchgit {
    name = "whalesong";
    url = "git://github.com/soegaard/whalesong.git";
    rev = "03c99841a3c4b40220ed5f05a2a772ed5d527b20";
    sha256 = "0907d2ilsz5ljhqc0l426y7p33164nysll5vj4nrz9hrwj0nc6zg";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "whalesong-tools" = self.lib.mkRacketDerivation rec {
  pname = "whalesong-tools";
  src = fetchgit {
    name = "whalesong-tools";
    url = "git://github.com/vishesh/drracket-whalesong.git";
    rev = "980bd29cdb77749627f21edeeb6aa76a3f80750a";
    sha256 = "18nxrdv1yw9p54zbbfm88am2q8n0x3m3znc0srg6g0lg861p9wg0";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."drracket-plugin-lib" self."whalesong" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "whereis" = self.lib.mkRacketDerivation rec {
  pname = "whereis";
  src = fetchgit {
    name = "whereis";
    url = "git://github.com/rmculpepper/racket-whereis.git";
    rev = "4e987ee3bc57b2fb64c44c419edca4a91b8de305";
    sha256 = "0dcal5x3afz98fibigy8baylkrrxk6qaj42mq62mnfbkmkq3nhjp";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "while-loop" = self.lib.mkRacketDerivation rec {
  pname = "while-loop";
  src = fetchgit {
    name = "while-loop";
    url = "git://github.com/jbclements/while-loop.git";
    rev = "69e33eef851c8db79536dcdb86bbfe113f7dcdda";
    sha256 = "0ski4r26brlxjfz7pr68822p7bamm6xa6vz7rdv77h5scnq6jh1p";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "with-cache" = self.lib.mkRacketDerivation rec {
  pname = "with-cache";
  src = fetchgit {
    name = "with-cache";
    url = "git://github.com/bennn/with-cache.git";
    rev = "4e1a5ced97bdbdca7affb4be4963f9f6c6cc8414";
    sha256 = "0v2yas7zglpm7qg45vvixwdfsdwl2dvzk5yq3s9g0l0ikqk0qzgh";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."basedir" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wn" = self.lib.mkRacketDerivation rec {
  pname = "wn";
  src = fetchgit {
    name = "wn";
    url = "git://github.com/themetaschemer/wn.git";
    rev = "3b134199c0a6c496323afd0f9573b33d5cc9e7e5";
    sha256 = "0x32f11cpfqcs17bhg739l77msgz9nsign5chrjwmsmnhavj3anc";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "word" = self.lib.mkRacketDerivation rec {
  pname = "word";
  src = fetchgit {
    name = "word";
    url = "https://gitlab.com/RayRacine/word.git";
    rev = "280659a27d2e3581fe64e8d406435cbcbadf3182";
    sha256 = "1zi95nwvbp5c9zg1r3h8qr758mzk079124qi7a9b42c3kwz3zvv0";
  };
  racketThinBuildInputs = [ self."typed-racket-more" self."typed-racket-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "words" = self.lib.mkRacketDerivation rec {
  pname = "words";
  src = fetchgit {
    name = "words";
    url = "git://github.com/mbutterick/words.git";
    rev = "c450d45984fe6e6718338a9cd2acd2a6a490ea01";
    sha256 = "1snh8sx2gxls0405sv9m8qcl3k9kavjklzlw9hvm41innf2krakr";
  };
  racketThinBuildInputs = [ self."gui-lib" self."base" self."debug" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wort" = self.lib.mkRacketDerivation rec {
  pname = "wort";
  src = fetchgit {
    name = "wort";
    url = "git://github.com/robertkleffner/wort.git";
    rev = "433130f0f6f1fa90d7ed21b857d03bce856656b0";
    sha256 = "0nl0dvq18b5bpn5i6mlr7ralixj1dy9jsnfx4xpdcg98f10d96kn";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."brag" self."beautiful-racket" self."beautiful-racket-lib" self."br-parser-tools-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wxme" = self.lib.mkRacketDerivation rec {
  pname = "wxme";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/wxme.zip";
    sha1 = "1b39d945a37ed146bb7a19acf7a4b28546e08786";
  };
  racketThinBuildInputs = [ self."wxme-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wxme-lib" = self.lib.mkRacketDerivation rec {
  pname = "wxme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/wxme-lib.zip";
    sha1 = "a801337c77c8cbbc4ba1130307084d1fe7eaf494";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wxme-test" = self.lib.mkRacketDerivation rec {
  pname = "wxme-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/wxme-test.zip";
    sha1 = "939da310079720d540d1278a2806f119ff36752d";
  };
  racketThinBuildInputs = [ self."rackunit" self."wxme-lib" self."base" self."gui-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "x11" = self.lib.mkRacketDerivation rec {
  pname = "x11";
  src = fetchgit {
    name = "x11";
    url = "git://github.com/kazzmir/x11-racket.git";
    rev = "b90ad3fd0eeafd617a6eb362e2edd9891c2876bd";
    sha256 = "059q9cvf85p442d8xiigi3kkdjkdfpj599h70a80jmzpnvsdxlz2";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."compatibility-lib" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "x64asm" = self.lib.mkRacketDerivation rec {
  pname = "x64asm";
  src = self.lib.extractPath {
    path = "x64asm";
    src = fetchgit {
    name = "x64asm";
    url = "git://github.com/yjqww6/racket-x64asm.git";
    rev = "71cf247a573514c6ade2c84d5b0813009375d516";
    sha256 = "12jxkidy9wxw3mxnnrfivdiy5chfz4p4dy0zjmcn848nphjl7mbp";
  };
  };
  racketThinBuildInputs = [ self."x64asm-lib" self."x64asm-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "x64asm-doc" = self.lib.mkRacketDerivation rec {
  pname = "x64asm-doc";
  src = self.lib.extractPath {
    path = "x64asm-doc";
    src = fetchgit {
    name = "x64asm-doc";
    url = "git://github.com/yjqww6/racket-x64asm.git";
    rev = "71cf247a573514c6ade2c84d5b0813009375d516";
    sha256 = "12jxkidy9wxw3mxnnrfivdiy5chfz4p4dy0zjmcn848nphjl7mbp";
  };
  };
  racketThinBuildInputs = [ self."base" self."x64asm-lib" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "x64asm-lib" = self.lib.mkRacketDerivation rec {
  pname = "x64asm-lib";
  src = self.lib.extractPath {
    path = "x64asm-lib";
    src = fetchgit {
    name = "x64asm-lib";
    url = "git://github.com/yjqww6/racket-x64asm.git";
    rev = "71cf247a573514c6ade2c84d5b0813009375d516";
    sha256 = "12jxkidy9wxw3mxnnrfivdiy5chfz4p4dy0zjmcn848nphjl7mbp";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xdgbasedir0" = self.lib.mkRacketDerivation rec {
  pname = "xdgbasedir0";
  src = fetchgit {
    name = "xdgbasedir0";
    url = "git://github.com/lawrencewoodman/xdgbasedir_rkt.git";
    rev = "ab6df3c5307b776547a9904625b2081a760e3045";
    sha256 = "08h8h3ii6cc9pqssj5sn101n8f5v48rksj7km9h5n0bl1bavd30b";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xe" = self.lib.mkRacketDerivation rec {
  pname = "xe";
  src = fetchgit {
    name = "xe";
    url = "git://github.com/tonyg/racket-xe.git";
    rev = "84e5cf72c34e6b3778c9353c22a3ebb0bb943d20";
    sha256 = "1kqgvwzaphv5wrlhk6iy1vimzpqcp0f3i8ldy4zq8z99i7nm1b8l";
  };
  racketThinBuildInputs = [ self."base" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xenomorph" = self.lib.mkRacketDerivation rec {
  pname = "xenomorph";
  src = fetchgit {
    name = "xenomorph";
    url = "git://github.com/mbutterick/xenomorph.git";
    rev = "79f7d14add9f675ac073362f154de2865c2c22f0";
    sha256 = "1akjbcppi5gfz3is3k3dvvjqa4vz76rbbvjwkvf36xlnpbikd7hw";
  };
  racketThinBuildInputs = [ self."base" self."beautiful-racket-lib" self."rackunit-lib" self."sugar" self."debug" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xexpr-path" = self.lib.mkRacketDerivation rec {
  pname = "xexpr-path";
  src = fetchgit {
    name = "xexpr-path";
    url = "git://github.com/mordae/racket-xexpr-path.git";
    rev = "59f07164a5735441953c411a78d7dbe2f8ebcdc0";
    sha256 = "02z1clh91fhmfbfdc4d689b24jb88292685kixwy89b2j03fihjp";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xfunctions" = self.lib.mkRacketDerivation rec {
  pname = "xfunctions";
  src = fetchgit {
    name = "xfunctions";
    url = "git://github.com/wesleybits/xfunctions.git";
    rev = "a8c545d55ee1d9df715ccc44fb22eec463e0f206";
    sha256 = "03h570a9dzlz0hb0vhlqhbr6lbgcjq3v4s9ydk53ba7wgxw3jyz3";
  };
  racketThinBuildInputs = [ self."base" self."xfunctions-lib" self."xfunctions-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xfunctions-doc" = self.lib.mkRacketDerivation rec {
  pname = "xfunctions-doc";
  src = self.lib.extractPath {
    path = "xfunctions-doc";
    src = fetchgit {
    name = "xfunctions-doc";
    url = "git://github.com/wesleybits/xfunctions.git";
    rev = "a8c545d55ee1d9df715ccc44fb22eec463e0f206";
    sha256 = "03h570a9dzlz0hb0vhlqhbr6lbgcjq3v4s9ydk53ba7wgxw3jyz3";
  };
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."xfunctions-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xfunctions-lib" = self.lib.mkRacketDerivation rec {
  pname = "xfunctions-lib";
  src = self.lib.extractPath {
    path = "xfunctions-lib";
    src = fetchgit {
    name = "xfunctions-lib";
    url = "git://github.com/wesleybits/xfunctions.git";
    rev = "a8c545d55ee1d9df715ccc44fb22eec463e0f206";
    sha256 = "03h570a9dzlz0hb0vhlqhbr6lbgcjq3v4s9ydk53ba7wgxw3jyz3";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xlang" = self.lib.mkRacketDerivation rec {
  pname = "xlang";
  src = fetchgit {
    name = "xlang";
    url = "git://github.com/samth/xlang.git";
    rev = "6672450a99cdf9aed7dcbcde2ab8e76063966973";
    sha256 = "15zlpkavhk5hmd121g3ivhds17ax5kppgw6hz2sfc3lqq5sc6cds";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xlist" = self.lib.mkRacketDerivation rec {
  pname = "xlist";
  src = fetchgit {
    name = "xlist";
    url = "git://github.com/jsmaniac/xlist.git";
    rev = "6455747fc6374bcb289f25e3ec0c5b3306e3a7f4";
    sha256 = "1arfr5clp5g261qz1gybm9lb99wkas30nihg6hqxqmirksbwrfji";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."mutable-match-lambda" self."scribble-enhanced" self."multi-id" self."type-expander" self."typed-racket-lib" self."typed-racket-more" self."phc-toolkit" self."reprovide-lang" self."match-string" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."scribble-math" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xml-html" = self.lib.mkRacketDerivation rec {
  pname = "xml-html";
  src = fetchgit {
    name = "xml-html";
    url = "git://github.com/zaoqi/xml-html.git";
    rev = "b4d38ef693d5dc1397c0a7dd822153617c41ea16";
    sha256 = "0iaamhlpxdqn3sadp5lldp2z0sdawmyp5lnr2c1cdvz4sirkk9bm";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xml-rpc" = self.lib.mkRacketDerivation rec {
  pname = "xml-rpc";
  src = fetchgit {
    name = "xml-rpc";
    url = "git://github.com/jeapostrophe/xml-rpc.git";
    rev = "ff4bb8aed216fcde3ef34c78908747dbfe026049";
    sha256 = "126bz442xwzd6a5hnbr1mix3rnbwdagvwrf9j483p40ija5qiaff";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."web-server-doc" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xmllint-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "xmllint-win32-x86_64";
  src = fetchgit {
    name = "xmllint-win32-x86_64";
    url = "git://github.com/LiberalArtist/xmllint-win32-x86_64.git";
    rev = "8b3ff2681a47bf0fb0036c8b900526e7a7a63086";
    sha256 = "1j68hjbhy7206q3ac2cf38fg4czx8p9x228fv23z1q5dmxciikws";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xmlns" = self.lib.mkRacketDerivation rec {
  pname = "xmlns";
  src = fetchgit {
    name = "xmlns";
    url = "git://github.com/lwhjp/racket-xmlns.git";
    rev = "b11d0010ceac1dac55b22d5eab51e24025593638";
    sha256 = "1pk2ninnyr2l3nc2q57xqn83rsdd0xj6kx8nai2ygsx3v232vjh1";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl" = self.lib.mkRacketDerivation rec {
  pname = "xrepl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/xrepl.zip";
    sha1 = "d8d78dbd1b77b573ecc4f9a2cace4fcc82b171f7";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."xrepl-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-doc" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/xrepl-doc.zip";
    sha1 = "c82598cec8ce7dcd24d5764da79f3fc39ca915cf";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."sandbox-lib" self."scribble-lib" self."macro-debugger-text-lib" self."profile-lib" self."readline-lib" self."xrepl-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-lib" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/xrepl-lib.zip";
    sha1 = "78a3f273852cc2bef7b564b5cec990a892b2284c";
  };
  racketThinBuildInputs = [ self."base" self."readline-lib" self."scribble-text-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-test" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/xrepl-test.zip";
    sha1 = "c9bfcff1936cc76ee14dc42c32d306c298c92047";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."eli-tester" self."xrepl-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xsmith" = self.lib.mkRacketDerivation rec {
  pname = "xsmith";
  src = self.lib.extractPath {
    path = "xsmith";
    src = fetchgit {
    name = "xsmith";
    url = "https://gitlab.flux.utah.edu/xsmith/xsmith.git";
    rev = "b6726a1c2976c489d2df3b23530036c24fdb670f";
    sha256 = "1s011pc2y3pm53n7z3wnxi77jcngb07n03shsz833iali6j3nb46";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."pprint" self."racr" self."rosette" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "yaml" = self.lib.mkRacketDerivation rec {
  pname = "yaml";
  src = fetchgit {
    name = "yaml";
    url = "git://github.com/esilkensen/yaml.git";
    rev = "e0729720be20d6ab72648b5be68063b6a65c1218";
    sha256 = "08hg9lsg506qh7rf4827l9yqf8jl1nq9khym9gcd6b0c7wibym5k";
  };
  racketThinBuildInputs = [ self."base" self."srfi-lite-lib" self."typed-racket-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "yotsubAPI" = self.lib.mkRacketDerivation rec {
  pname = "yotsubAPI";
  src = fetchgit {
    name = "yotsubAPI";
    url = "git://github.com/g-gundam/yotsubAPI.git";
    rev = "cbf312862fc4e94deb74790a2756d5745e5463fc";
    sha256 = "15h6g6sd0kiadg7kvdrxhg4bd0a142ink5h8fhdcgzq6hgsx7i04";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "z3" = self.lib.mkRacketDerivation rec {
  pname = "z3";
  src = self.lib.extractPath {
    path = "z3/";
    src = fetchgit {
    name = "z3";
    url = "git://github.com/philnguyen/z3-rkt.git";
    rev = "78deda2c7a377b93caefd40fd16e5df9c6d53c40";
    sha256 = "0m3hyan3v41hmn3ixkzvn9c0mhvw60grcd41ji7s06al3n8fpwnj";
  };
  };
  racketThinBuildInputs = [ self."base" self."html-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zKanren" = self.lib.mkRacketDerivation rec {
  pname = "zKanren";
  src = fetchgit {
    name = "zKanren";
    url = "git://github.com/the-language/zKanren2.git";
    rev = "82c936ed11fa703b3b26895b3a2d7b7f379a8c35";
    sha256 = "0506aa0l7v95my9dncxblmnp1jdf2d16xbyyvdh8x28r6aimr4m6";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."typed-racket" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq" = self.lib.mkRacketDerivation rec {
  pname = "zeromq";
  src = fetchgit {
    name = "zeromq";
    url = "git://github.com/jeapostrophe/zeromq.git";
    rev = "cff2ce12fd39e5830628a48f479b917b290c5036";
    sha256 = "1lzf13mnnwq589320qx7a6nir37rwysalbkvh0xzz1bbxx8v328d";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."at-exp-lib" self."racket-doc" self."math-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq-r" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-r";
  src = self.lib.extractPath {
    path = "zeromq-r";
    src = fetchgit {
    name = "zeromq-r";
    url = "git://github.com/rmculpepper/racket-zeromq.git";
    rev = "760f8a8a0b3bdf544e953fd972f8bf976faba3e8";
    sha256 = "04d72x03srxfa4hsjlz77a4w21i6ldv42hnc0zv1ldn0zf9lqkz0";
  };
  };
  racketThinBuildInputs = [ self."base" self."zeromq-r-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq-r-lib" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-r-lib";
  src = self.lib.extractPath {
    path = "zeromq-r-lib";
    src = fetchgit {
    name = "zeromq-r-lib";
    url = "git://github.com/rmculpepper/racket-zeromq.git";
    rev = "760f8a8a0b3bdf544e953fd972f8bf976faba3e8";
    sha256 = "04d72x03srxfa4hsjlz77a4w21i6ldv42hnc0zv1ldn0zf9lqkz0";
  };
  };
  racketThinBuildInputs = [ self."base" self."zeromq-win32-i386" self."zeromq-win32-x86_64" self."zeromq-x86_64-linux-natipkg" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-win32-i386";
  src = self.lib.extractPath {
    path = "zeromq-win32-i386";
    src = fetchgit {
    name = "zeromq-win32-i386";
    url = "git://github.com/rmculpepper/racket-natipkg-zeromq.git";
    rev = "c9c89e3542508d753384c62ab368b3585796be8b";
    sha256 = "144s6nxjyxm9alf9dqf338spq9jjc4n99c8bxl7z9y415lf3i88k";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-win32-x86_64";
  src = self.lib.extractPath {
    path = "zeromq-win32-x86_64";
    src = fetchgit {
    name = "zeromq-win32-x86_64";
    url = "git://github.com/rmculpepper/racket-natipkg-zeromq.git";
    rev = "c9c89e3542508d753384c62ab368b3585796be8b";
    sha256 = "144s6nxjyxm9alf9dqf338spq9jjc4n99c8bxl7z9y415lf3i88k";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zeromq-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-x86_64-linux-natipkg";
  src = self.lib.extractPath {
    path = "zeromq-x86_64-linux-natipkg";
    src = fetchgit {
    name = "zeromq-x86_64-linux-natipkg";
    url = "git://github.com/rmculpepper/racket-natipkg-zeromq.git";
    rev = "c9c89e3542508d753384c62ab368b3585796be8b";
    sha256 = "144s6nxjyxm9alf9dqf338spq9jjc4n99c8bxl7z9y415lf3i88k";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zippers" = self.lib.mkRacketDerivation rec {
  pname = "zippers";
  src = fetchgit {
    name = "zippers";
    url = "git://github.com/david-christiansen/racket-zippers.git";
    rev = "ab11342e1359b0844f8f19f801cdd02d697f7ec3";
    sha256 = "1z5cb0jrspxjhbj18dxsqjs3r8a6kry5qvz55l7s7w9gzzrwy191";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zmq" = self.lib.mkRacketDerivation rec {
  pname = "zmq";
  src = fetchgit {
    name = "zmq";
    url = "git://github.com/mordae/racket-zmq.git";
    rev = "5d936df13adce486ac23c5e921099de10ad9bf61";
    sha256 = "1bzzv0gmlb6insqq3cnjam90r2vkaa3mh6ndndn0b40zp7frkzaf";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."misc1" self."mordae" self."typed-racket-lib" self."racket-doc" self."typed-racket-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zo-lib" = self.lib.mkRacketDerivation rec {
  pname = "zo-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.7/pkgs/zo-lib.zip";
    sha1 = "9236b5acf711295467025f920a4df916aeff960c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zordoz" = self.lib.mkRacketDerivation rec {
  pname = "zordoz";
  src = fetchgit {
    name = "zordoz";
    url = "git://github.com/bennn/zordoz.git";
    rev = "00f68d7e00fbf271a95c3f120a2d9fe5b598b7e9";
    sha256 = "1pjsny35vmj92ypnsj8w2fqvg3rjpjk7gjs8gcy3l8f5a4rhmpv1";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."zo-lib" self."typed-racket-lib" self."typed-racket-more" self."readline-lib" self."dynext-lib" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "zubat" = self.lib.mkRacketDerivation rec {
  pname = "zubat";
  src = fetchgit {
    name = "zubat";
    url = "git://github.com/kalxd/zubat.git";
    rev = "1ab12af215e694de2ff695bc41a139bd6de5bac6";
    sha256 = "0hg8vz3rprmn14cy6n5s2nb9y9z3gv27lnxmsk4n54k77xh4xl13";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."sxml" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
}); in
racket-packages
