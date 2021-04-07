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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/2d.zip";
    sha1 = "343275dc6185d080999fb15da83a60063666617d";
  };
  racketThinBuildInputs = [ self."2d-lib" self."2d-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-doc" = self.lib.mkRacketDerivation rec {
  pname = "2d-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/2d-doc.zip";
    sha1 = "1e724e93c5b9ecc6089719ec847ec6e6df90d911";
  };
  racketThinBuildInputs = [ self."base" self."2d-lib" self."scribble-lib" self."racket-doc" self."syntax-color-doc" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-lib" = self.lib.mkRacketDerivation rec {
  pname = "2d-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/2d-lib.zip";
    sha1 = "2d70b1241a4aef903a9feb3c64ca73e0b006bd2e";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."syntax-color-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "2d-test" = self.lib.mkRacketDerivation rec {
  pname = "2d-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/2d-test.zip";
    sha1 = "2fb724a290b2b830e8ce2ce20c57b893b50acd3e";
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
    url = "https://gitlab.com/oquijano/sse.git";
    rev = "a6858b7ca41a6ab482c170e6223dc8ac4c7f4eb2";
    sha256 = "1pplk090pa563f0wzd26pgm5nakgx654mnw60awdwdh23lqnbb29";
  };
  racketThinBuildInputs = [ self."base" self."web-server-lib" self."web-server-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "1cfa52f65ec00a9c0fbf3c8575634961d793387b";
    sha256 = "0b355dgs3swhdmzd3bc2d1y12dnn1fh3qjfh6d283j67zndki50p";
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
    rev = "4070f50877ff182b93f1586e0482d6f0ba851dc7";
    sha256 = "1dncgf3r9qzb6drfk4dix4bk3yxghb0qq2266z7fx9sjj5ay1k0v";
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
    rev = "e7f7270bdb70708f58bbda27ffad07509085e5fe";
    sha256 = "17vqhcg9886s9a7xifsyhlkk6vyg86n7ky6zr0dncnlgnq22ala8";
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
  "al2-test-runner" = self.lib.mkRacketDerivation rec {
  pname = "al2-test-runner";
  src = fetchgit {
    name = "al2-test-runner";
    url = "git://github.com/alex-hhh/al2-test-runner.git";
    rev = "b6757271932151dff6507ee6f1b690d0268da808";
    sha256 = "1sys1f2h79xcsl1n93d8mq0w1pm0gkijbv50dnx6hxp8kqd2digy";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."sandbox-lib" self."racket-doc" self."rackunit-doc" self."scribble-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/algol60.zip";
    sha1 = "c614990f71f1f3c7150857b88ab60f3e4c9b801a";
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
    rev = "b114ca74b632cd112d51509e79d2cf4f7aa55d2f";
    sha256 = "1vgsw7r33c5r9fdwlijxwaybgrjwc9qrb7238qcbb2zg2mfvlq1k";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "amap" = self.lib.mkRacketDerivation rec {
  pname = "amap";
  src = fetchgit {
    name = "amap";
    url = "git://github.com/yanyingwang/amap.git";
    rev = "dd963660bb1b8e5b6bfd447e56ba8e780424a865";
    sha256 = "0g36xaqh975z80bscdl5igyf43gyhrffpbffkhb4rx1rpg9ir7l7";
  };
  racketThinBuildInputs = [ self."base" self."request" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "anaphoric" = self.lib.mkRacketDerivation rec {
  pname = "anaphoric";
  src = fetchgit {
    name = "anaphoric";
    url = "git://github.com/jsmaniac/anaphoric.git";
    rev = "c9baafe8a6a0ab924ca6474b6963b701db062222";
    sha256 = "1ias1m5kn3l4x325b11f10j4mdpmscid779sq7zhmhg1lc9j13bk";
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
    rev = "617669c7e3fd7df4fed24b0c7dd19c80687b0595";
    sha256 = "1853ccqp0xx4nbx2g2mnd95i9q7ywysnb4fln4k9cpm4z7mdmw3s";
  };
  racketThinBuildInputs = [ self."base" self."sha" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "andlet" = self.lib.mkRacketDerivation rec {
  pname = "andlet";
  src = fetchgit {
    name = "andlet";
    url = "https://bitbucket.org/derend/andlet.git";
    rev = "2da90e6a47c2f87c57d05d9bd7bc221677d4b9d5";
    sha256 = "044jzxpy3nh3x56ff8230cf0pwp7iylhjqkmgj4fhixg40qj77y3";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
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
    rev = "c14081de59bc7273f1f9088a51d6d9c202b2b9d0";
    sha256 = "0l8km828y9nxcxszinkpkazyjq73h5fk8d8rhhqlfg7nqg3ad9f3";
  };
  racketThinBuildInputs = [ self."base" self."dynext-lib" ];
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
    rev = "2c6cb2f3ad876a91a82f33ce12844f7758b969d6";
    sha256 = "0ba9jf291gbdl5bjll1c7ix2lmvnj27gk7k5grkvprk2w6y3nv1r";
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
    rev = "5e8e2a1dd125e5e437510c87dabf903d0ec25749";
    sha256 = "0mwn2mf15sbhcng65n5334dasgl95x9i2wnrzw79h0pnip1yjz1i";
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
    rev = "57abd235fcb8c7505990f8e9731c01c716324ee5";
    sha256 = "1lq35y5xjz3vjqja2pmi1gfms285fqsqmph4fajmi94d1mrbzv36";
  };
  racketThinBuildInputs = [ self."base" self."binutils" self."data-lib" self."racklog" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
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
    rev = "3afe9706302fcc6763f8d61622dee83ab6fa0c26";
    sha256 = "1z9vafb4rilm9mgym8iza34mjal1bmljgxvp1qbv8yir35420bjr";
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
    rev = "3afe9706302fcc6763f8d61622dee83ab6fa0c26";
    sha256 = "1z9vafb4rilm9mgym8iza34mjal1bmljgxvp1qbv8yir35420bjr";
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
    rev = "3afe9706302fcc6763f8d61622dee83ab6fa0c26";
    sha256 = "1z9vafb4rilm9mgym8iza34mjal1bmljgxvp1qbv8yir35420bjr";
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
    rev = "3afe9706302fcc6763f8d61622dee83ab6fa0c26";
    sha256 = "1z9vafb4rilm9mgym8iza34mjal1bmljgxvp1qbv8yir35420bjr";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/at-exp-lib.zip";
    sha1 = "5a9b01c45b06d3b5987d08c0d4bbea87776a7b02";
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
    rev = "77dddb12241a8d7ca8f1520a1862a79cad91a6c6";
    sha256 = "0klpmlqk9zxvl4y87fafs98fp4lc2hpdwx3036wf6r2qcfycawc0";
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
    rev = "89ddc98f2ca2e1a667be655dade7314280b067e7";
    sha256 = "011x990ckpdaihfqkr0kwyvmsngdx7v5wshr6fdhqb5npx9k1yci";
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
    rev = "6abe851b83b18fcdcb8f2b19ab87cdabc90c71ce";
    sha256 = "05bbjrjjdsirlyaqyr6l1rqf26nbqs4cw8vprwris7ia08jhynqy";
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
    rev = "6abe851b83b18fcdcb8f2b19ab87cdabc90c71ce";
    sha256 = "05bbjrjjdsirlyaqyr6l1rqf26nbqs4cw8vprwris7ia08jhynqy";
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
    rev = "6abe851b83b18fcdcb8f2b19ab87cdabc90c71ce";
    sha256 = "05bbjrjjdsirlyaqyr6l1rqf26nbqs4cw8vprwris7ia08jhynqy";
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
    rev = "6abe851b83b18fcdcb8f2b19ab87cdabc90c71ce";
    sha256 = "05bbjrjjdsirlyaqyr6l1rqf26nbqs4cw8vprwris7ia08jhynqy";
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
    rev = "94a16a6875ac585a10fc488b1bf48052172d5668";
    sha256 = "0vk5y6a9h9nq19ssf7mp1fkpkz2nl666bzngvjdjn26xvg4yvf22";
  };
  racketThinBuildInputs = [ self."base" self."http" self."sha" self."at-exp-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
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
  "azelf" = self.lib.mkRacketDerivation rec {
  pname = "azelf";
  src = fetchgit {
    name = "azelf";
    url = "git://github.com/kalxd/azelf.git";
    rev = "bada24159034c867dbb8d4d2d33c62be59025ac6";
    sha256 = "1r8p3mzz2cvbs7f5zw015jgjnrrl9zg30yi10dcbidndms304v2x";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "backport-template-pr1514" = self.lib.mkRacketDerivation rec {
  pname = "backport-template-pr1514";
  src = fetchgit {
    name = "backport-template-pr1514";
    url = "git://github.com/jsmaniac/backport-template-pr1514.git";
    rev = "a6c3611fcddb8d8a67531694c9b8c2c4f89bbb0f";
    sha256 = "1rihnrlzxmczjvf8pd5yrxpslj75snm2q8cj58kaqafx96vnappy";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."version-case" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "base" = self.lib.mkRacketDerivation rec {
  pname = "base";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/base.zip";
    sha1 = "619dcdb8f76e302f7852f90592fe822c8b959f7f";
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
  "base58" = self.lib.mkRacketDerivation rec {
  pname = "base58";
  src = fetchgit {
    name = "base58";
    url = "git://github.com/marckn0x/base58.git";
    rev = "125186f659f29a9f7275540c6211885784a68edd";
    sha256 = "0prfkf51y65afbpa40n15flkh9rsmx8q4z1slhffr06vk7ycidf7";
  };
  racketThinBuildInputs = [ self."base" self."binaryio" self."sha" self."typed-racket-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."rackunit-typed" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "base64" = self.lib.mkRacketDerivation rec {
  pname = "base64";
  src = self.lib.extractPath {
    path = "base64";
    src = fetchgit {
    name = "base64";
    url = "git://github.com/rmculpepper/racket-base64.git";
    rev = "f3ff606785a553651d79c2e846b35fe84be9b2b0";
    sha256 = "1gghbvdhxvwclhbas816ac3v2jdhs6v7jb1n9ymg378zignq44gc";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-lib" self."rackunit-lib" self."base64-lib" self."racket-doc" self."scribble-lib" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "base64-lib" = self.lib.mkRacketDerivation rec {
  pname = "base64-lib";
  src = self.lib.extractPath {
    path = "base64-lib";
    src = fetchgit {
    name = "base64-lib";
    url = "git://github.com/rmculpepper/racket-base64.git";
    rev = "f3ff606785a553651d79c2e846b35fe84be9b2b0";
    sha256 = "1gghbvdhxvwclhbas816ac3v2jdhs6v7jb1n9ymg378zignq44gc";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "basedir" = self.lib.mkRacketDerivation rec {
  pname = "basedir";
  src = fetchgit {
    name = "basedir";
    url = "git://github.com/willghatch/racket-basedir.git";
    rev = "ef95b1eeb9b4e0df491680e5caa98eeadf64dfa1";
    sha256 = "0xdy48mp86mi0ymz3a28vkr4yc6gid32nkjvdkhz81m5v51yxa9s";
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
    rev = "8432d3c5398225a4bfb5ed5c25a1beffa06409ec";
    sha256 = "11w5w8z6w19img7q9xhsdbxhbx3v201nmsc4fgka7a2pbm019pbf";
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
    rev = "ea48022513c673a735e5e4dd8e16d1ded4ce4ca7";
    sha256 = "0p0lx4wa9ypiyqlxc6fzkny8c610m3996878rz62l225d66f77gv";
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
    rev = "d75a344bee405cdb6a337decacca042a500b5c79";
    sha256 = "0b647603w7vbf33pama8fdl9rglrkwzj75jznlw2fd260v7r54n4";
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
    rev = "d75a344bee405cdb6a337decacca042a500b5c79";
    sha256 = "0b647603w7vbf33pama8fdl9rglrkwzj75jznlw2fd260v7r54n4";
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
    rev = "d75a344bee405cdb6a337decacca042a500b5c79";
    sha256 = "0b647603w7vbf33pama8fdl9rglrkwzj75jznlw2fd260v7r54n4";
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
    rev = "d75a344bee405cdb6a337decacca042a500b5c79";
    sha256 = "0b647603w7vbf33pama8fdl9rglrkwzj75jznlw2fd260v7r54n4";
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
  "biginterval" = self.lib.mkRacketDerivation rec {
  pname = "biginterval";
  src = fetchgit {
    name = "biginterval";
    url = "git://github.com/oflatt/biginterval.git";
    rev = "81b0fdb5de11aeaeaf651f9e32c613c4584756ee";
    sha256 = "0jylbwjgvjxpf97m1xa6zv168m3k0qab1v5ws1z05921x7r1ls0p";
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
    rev = "ddad0c7fa1e1f7a3b990809bcccbd521204e2fd0";
    sha256 = "1xv84hr78g7jwcxvz37anlxvnbyd529lbcik62957za58rhfvi3s";
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
    rev = "6157d5bc79028bdb9445fa9ad216b22f80c54ffd";
    sha256 = "1v3nlzhc54vhrypksggx99j1d5khgj40pa1b6q3bgq8z19rlmgvp";
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
    rev = "6157d5bc79028bdb9445fa9ad216b22f80c54ffd";
    sha256 = "1v3nlzhc54vhrypksggx99j1d5khgj40pa1b6q3bgq8z19rlmgvp";
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
    rev = "a72ef077e2d00ec776f12c0e497c6517f66dfe16";
    sha256 = "14izpr76hfcd86s820rh36mxzbnfglgmcb4c2h9hl2r18d51xk7n";
  };
  racketThinBuildInputs = [ self."base" self."binary-class" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "bip32" = self.lib.mkRacketDerivation rec {
  pname = "bip32";
  src = fetchgit {
    name = "bip32";
    url = "git://github.com/marckn0x/bip32.git";
    rev = "19f4460abd1f5fdacaa651064c4d8353401294f0";
    sha256 = "1g3f14a0gnrk86ydkxn29rnmrvf6yadjwh1ygi2873hv6ij0mzmf";
  };
  racketThinBuildInputs = [ self."base" self."binaryio" self."sha" self."crypto" self."base58" self."ec" self."typed-racket-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."rackunit-typed" ];
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
    rev = "32fc3b68d14a027ec70fb5cca38471ebdfed9ee7";
    sha256 = "0pbwn980qlkn4hr37bajxk811bwjrldf1dx8m5kc2lxgqdyxshzx";
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
    rev = "32fc3b68d14a027ec70fb5cca38471ebdfed9ee7";
    sha256 = "0pbwn980qlkn4hr37bajxk811bwjrldf1dx8m5kc2lxgqdyxshzx";
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
    rev = "32fc3b68d14a027ec70fb5cca38471ebdfed9ee7";
    sha256 = "0pbwn980qlkn4hr37bajxk811bwjrldf1dx8m5kc2lxgqdyxshzx";
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
    rev = "6c161ae31df9b4ae7f55a14f754c0b216b60c9a6";
    sha256 = "0fydyqghxv8arpz5py5c8rvpfldl68208pkhqhhfwyanbk5wkgdk";
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
    rev = "6c161ae31df9b4ae7f55a14f754c0b216b60c9a6";
    sha256 = "0fydyqghxv8arpz5py5c8rvpfldl68208pkhqhhfwyanbk5wkgdk";
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
  "bsd-sysv-checksum" = self.lib.mkRacketDerivation rec {
  pname = "bsd-sysv-checksum";
  src = fetchgit {
    name = "bsd-sysv-checksum";
    url = "git://github.com/jeroanan/bsd-sysv-checksum.git";
    rev = "b4c5dcf2c24d56bcd5eef2e3885458eaf6f164d4";
    sha256 = "1sl73cgz03q7723i791kznzl0ryv5bk8mlaa9sxj2zp8q3maazca";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "3d1fdc02432dc7bb839802f499834bd3345e54bf";
    sha256 = "104h5vgjd1rhby502jvhxgf570i17fijs8wj1whbnqslf5c3yifx";
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
    rev = "30bd054e9f9e02e7415b4247e4ca3360483771bd";
    sha256 = "0rf5s9cdzlc6amvmwyxpmvjqdfsqnbwqqm2ff6m1mmlwwizclad0";
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
    rev = "195c155ccf9306acd29adaf2ab7d536d7686f849";
    sha256 = "15rc5qhbb5vff2aga0c58ismr58c7in8pcvl68g13qprkapa1qxl";
  };
  racketThinBuildInputs = [ self."base" self."brag-lib" self."db" self."graph" self."math-lib" self."rackunit-lib" self."scribble-lib" self."csv-writing" self."racket-graphviz" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."math-doc" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/cext-lib.zip";
    sha1 = "f131944932cec9cd44ffe38c7aa88223de2871e3";
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
    rev = "77fca59322b93cb83a2d57c25546dd7a7313bc56";
    sha256 = "1wpgrs7n0fpba1880mxx17yyj10zaz2w8lir3p6mqyqv7df1n1y9";
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
    rev = "cd7aaa015ddaa87026b11dfe8dbe6778409b5286";
    sha256 = "1nax82hr3dkz10gpawyw7d6zjbb67gxnn68b2ds8x9izabywk8rc";
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
    rev = "413c49e9760c0313809ecbf9ccee9772413cb336";
    sha256 = "0ylwgiy18xhixiagfpdwsdwchxmc1k62kk475369qq36ldii8v5x";
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
  "cksum" = self.lib.mkRacketDerivation rec {
  pname = "cksum";
  src = fetchgit {
    name = "cksum";
    url = "git://github.com/jeroanan/cksum.git";
    rev = "ea390924866cb53df44f4d812c1f187e2e88b8a7";
    sha256 = "0c3k89s6y7dwrdfqsdi09nzgn1pfx46j4jmb7jxd9dmj09hlhgzw";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "clang" = self.lib.mkRacketDerivation rec {
  pname = "clang";
  src = fetchgit {
    name = "clang";
    url = "git://github.com/wargrey/clang.git";
    rev = "b9d008a4bf914474fa3368095e93a5c4925dc9f5";
    sha256 = "1gi8lr50a0v3kcb2qy1d4va043s8011y19z34ig6pbmwbvkl06z3";
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/class-iop-lib.zip";
    sha1 = "cbc77379a1a254bf1bc78eb1e3881ec0ca8f8cc1";
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
  "clotho" = self.lib.mkRacketDerivation rec {
  pname = "clotho";
  src = self.lib.extractPath {
    path = "clotho";
    src = fetchgit {
    name = "clotho";
    url = "https://gitlab.flux.utah.edu/xsmith/clotho.git";
    rev = "7cc309787f07286e3b1411346f4e85e4bec09098";
    sha256 = "02qfkvdbar8sbbm04prh6jd8az1wj6zvq8ssad0993g2p5qvhkzj";
  };
  };
  racketThinBuildInputs = [ self."base" self."version-string-with-git-hash" self."rackunit-lib" self."math-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "code-sync" = self.lib.mkRacketDerivation rec {
  pname = "code-sync";
  src = fetchgit {
    name = "code-sync";
    url = "git://github.com/rymaju/code-sync.git";
    rev = "feea02e2cc19088ba7ce5336b89b22044d5dafcf";
    sha256 = "1jrgaijairy9v9rjx88j5wdd8day9ifrqmdzrm4hb96fqvyp702i";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."data-lib" self."drracket-plugin-lib" self."rfc6455" self."net" self."web-server-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "codespells-live" = self.lib.mkRacketDerivation rec {
  pname = "codespells-live";
  src = fetchgit {
    name = "codespells-live";
    url = "git://github.com/ldhandley/codespells-live.git";
    rev = "a328d5dc5ab8846e39ab59831938b566d63aab86";
    sha256 = "1gxfmlqqd7fak6417pwajyphm54lmydx35l5f375hff2lmngyq5v";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "c4822fc200b0488922cd6e86b4f2ea7cf8c565da";
    sha256 = "0zaylzl54ij7kd8k5zgzjh1wk0m5vj954dj95f2iplg8w1s3w147";
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
    rev = "c4822fc200b0488922cd6e86b4f2ea7cf8c565da";
    sha256 = "0zaylzl54ij7kd8k5zgzjh1wk0m5vj954dj95f2iplg8w1s3w147";
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
    rev = "c4822fc200b0488922cd6e86b4f2ea7cf8c565da";
    sha256 = "0zaylzl54ij7kd8k5zgzjh1wk0m5vj954dj95f2iplg8w1s3w147";
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
    rev = "c4822fc200b0488922cd6e86b4f2ea7cf8c565da";
    sha256 = "0zaylzl54ij7kd8k5zgzjh1wk0m5vj954dj95f2iplg8w1s3w147";
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
  "colophon" = self.lib.mkRacketDerivation rec {
  pname = "colophon";
  src = fetchgit {
    name = "colophon";
    url = "git://github.com/basus/colophon.git";
    rev = "04989fbffb385a09d4f6b83ab9a132fa85ec8454";
    sha256 = "06d02ch2qy6hxp5vdvw60xx2clpai2phv71n5x1hx7m59g8dhkmf";
  };
  racketThinBuildInputs = [ self."base" self."pollen" self."scribble-doc" self."racket-doc" self."scribble-lib" ];
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
    rev = "f0dc88be58bae0d0331bfa778987460d7d71a08a";
    sha256 = "0dk1cavkhiy24rn0p3xq7wxbhhd95742836xwyambcvpcq5226i5";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/com-win32-i386.zip";
    sha1 = "43555aa8af94e8aa35a06e4331b1cb58aba6200a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "com-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "com-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/com-win32-x86_64.zip";
    sha1 = "e126d66512910de3b00c2624a6afb01f42f6b3ff";
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
    rev = "e980b3b31d7a0cb6e0339335bde860f35a0fe471";
    sha256 = "0qy4p66dbwqsvf1cdwaq3dlrllkgywrgh5izc3fcjjiy65s44719";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compatibility.zip";
    sha1 = "36cb8640b41033ee50a57ebdfb9bfd5aabfba7f2";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." = self.lib.mkRacketDerivation rec {
  pname = "compatibility+compatibility-doc+data-doc+db-doc+distributed-p...";

  extraSrcs = [ self."racket-doc".src self."readline".src self."draw".src self."syntax-color".src self."parser-tools-doc".src self."compatibility".src self."pict".src self."future-visualizer".src self."distributed-places-doc".src self."distributed-places".src self."trace".src self."planet-doc".src self."quickscript".src self."drracket-tool-doc".src self."drracket".src self."gui".src self."xrepl".src self."typed-racket-doc".src self."slideshow-doc".src self."pict-doc".src self."draw-doc".src self."syntax-color-doc".src self."string-constants-doc".src self."readline-doc".src self."macro-debugger".src self."errortrace-doc".src self."profile-doc".src self."xrepl-doc".src self."gui-doc".src self."scribble-doc".src self."net-cookies-doc".src self."net-doc".src self."compatibility-doc".src self."rackunit-doc".src self."web-server-doc".src self."db-doc".src self."mzscheme-doc".src self."r5rs-doc".src self."r6rs-doc".src self."srfi-doc".src self."plot-doc".src self."math-doc".src self."data-doc".src ];
  racketThinBuildInputs = [ self."2d-lib" self."at-exp-lib" self."base" self."cext-lib" self."class-iop-lib" self."compatibility-lib" self."compiler-lib" self."data-enumerate-lib" self."data-lib" self."db-lib" self."distributed-places-lib" self."draw-lib" self."drracket-plugin-lib" self."drracket-tool-lib" self."errortrace-lib" self."future-visualizer-pict" self."gui-lib" self."gui-pkg-manager-lib" self."htdp-lib" self."html-lib" self."icons" self."images-gui-lib" self."images-lib" self."macro-debugger-text-lib" self."math-lib" self."net-cookies-lib" self."net-lib" self."option-contract-lib" self."parser-tools-lib" self."pconvert-lib" self."pict-lib" self."pict-snip-lib" self."planet-lib" self."plot-compat" self."plot-gui-lib" self."plot-lib" self."profile-lib" self."r5rs-lib" self."r6rs-lib" self."racket-index" self."rackunit-gui" self."rackunit-lib" self."readline-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."scribble-text-lib" self."serialize-cstruct-lib" self."slideshow-lib" self."snip-lib" self."srfi-lib" self."srfi-lite-lib" self."string-constants-lib" self."syntax-color-lib" self."tex-table" self."typed-racket-compatibility" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."wxme-lib" self."xrepl-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  };
  "compatibility-doc" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compatibility-doc.zip";
    sha1 = "8e9951761a82fbcf19ba4d6a6944ee1f9b0eeb5e";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."compatibility-lib" self."pconvert-lib" self."sandbox-lib" self."compiler-lib" self."gui-lib" self."scheme-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility-lib" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compatibility-lib.zip";
    sha1 = "7166abf2fb5b2a56c8343029a6d44e43c9f1e151";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."net-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compatibility-test" = self.lib.mkRacketDerivation rec {
  pname = "compatibility-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compatibility-test.zip";
    sha1 = "db6597e099a4d342252ed98275dccf026f77ee1e";
  };
  racketThinBuildInputs = [ self."base" self."racket-test" self."compatibility-lib" self."drracket-tool-lib" self."rackunit-lib" self."pconvert-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler" = self.lib.mkRacketDerivation rec {
  pname = "compiler";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compiler.zip";
    sha1 = "a40d420cd2a67d5632be9075c66438044b432c00";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compiler-lib.zip";
    sha1 = "b41bd31a445bec03d82f6412fd6f03d7eda07d27";
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."rackunit-lib" self."zo-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "compiler-test" = self.lib.mkRacketDerivation rec {
  pname = "compiler-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/compiler-test.zip";
    sha1 = "5c873360e608cbc39f71c62f8d3b6c66fba43485";
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
    rev = "6dd5378caf4eea1a6ef0171909505d4bd5e86b8c";
    sha256 = "19h3iv1ra3dvfivdpkhf9h1mwivvsfrz1jvqjnx8ygmaylv05jab";
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
    rev = "6dd5378caf4eea1a6ef0171909505d4bd5e86b8c";
    sha256 = "19h3iv1ra3dvfivdpkhf9h1mwivvsfrz1jvqjnx8ygmaylv05jab";
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
    rev = "6dd5378caf4eea1a6ef0171909505d4bd5e86b8c";
    sha256 = "19h3iv1ra3dvfivdpkhf9h1mwivvsfrz1jvqjnx8ygmaylv05jab";
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
    rev = "6dd5378caf4eea1a6ef0171909505d4bd5e86b8c";
    sha256 = "19h3iv1ra3dvfivdpkhf9h1mwivvsfrz1jvqjnx8ygmaylv05jab";
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
  "contract-etc" = self.lib.mkRacketDerivation rec {
  pname = "contract-etc";
  src = fetchgit {
    name = "contract-etc";
    url = "git://github.com/camoy/contract-etc.git";
    rev = "6629c4f5011417022e0b8b7e20265a5ae4f0b222";
    sha256 = "06gps96xica72235sbzglz20622h9i37f84q7nnm81jl65f3210f";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."chk-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "contract-parameter" = self.lib.mkRacketDerivation rec {
  pname = "contract-parameter";
  src = fetchgit {
    name = "contract-parameter";
    url = "git://github.com/camoy/contract-parameter.git";
    rev = "762d1ebfbce61320c84ce655158acaa254147332";
    sha256 = "06kiw7pls16f1a3fpy0fgdjbq3qcgn36nxzj38409xxka313zczf";
  };
  racketThinBuildInputs = [ self."contract-etc" self."base" self."chk-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "contract-profile" = self.lib.mkRacketDerivation rec {
  pname = "contract-profile";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/contract-profile.zip";
    sha1 = "63cdff9051104ac66799e92d9e5a3fdc840045c7";
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
    rev = "fec745e8af7e3f4d5eaf83407dde2817de4c2eb0";
    sha256 = "17qylrsxzl0gc8j7niqqxnjf5fl1nfqyr0wx323masw3a89f2bnx";
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
    rev = "fec745e8af7e3f4d5eaf83407dde2817de4c2eb0";
    sha256 = "17qylrsxzl0gc8j7niqqxnjf5fl1nfqyr0wx323masw3a89f2bnx";
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
    rev = "fec745e8af7e3f4d5eaf83407dde2817de4c2eb0";
    sha256 = "17qylrsxzl0gc8j7niqqxnjf5fl1nfqyr0wx323masw3a89f2bnx";
  };
  };
  racketThinBuildInputs = [ self."base" self."asn1-lib" self."base64-lib" self."binaryio-lib" self."gmp-lib" ];
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
    rev = "fec745e8af7e3f4d5eaf83407dde2817de4c2eb0";
    sha256 = "17qylrsxzl0gc8j7niqqxnjf5fl1nfqyr0wx323masw3a89f2bnx";
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
    path = "rktboot";
    src = fetchgit {
    name = "cs-bootstrap";
    url = "git://github.com/racket/ChezScheme.git";
    rev = "341024292bc582ad158a283977643ae86579bf76";
    sha256 = "0z3pw87lg84a9lq558a7j04ikzzvccvd5h343d84piwm7v6bkaiv";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "cs135-drtools" = self.lib.mkRacketDerivation rec {
  pname = "cs135-drtools";
  src = fetchgit {
    name = "cs135-drtools";
    url = "git://github.com/Raymo111/cs135-drtools.git";
    rev = "75c7041944ac489cacfe9327a7a936aafb576983";
    sha256 = "0r0hmyb12cm9796q3l0asgm84v8xzzs0iz2cwgkh79j20s6322ra";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "7bcd88b848d054b5d847a51f65eb90988c260b81";
    sha256 = "1mi48yjv3ns5l7014hkgm5zm7w1bb1aiwblvzndb1hmx5h722nzq";
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
    rev = "064e675cb06e3ec63714baaa39497f6c3b7f2c20";
    sha256 = "0gqaykc4bjr47ccagy379cksl4srmjy637xkmwz19jq2akwrcz14";
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
    rev = "f065107c46cc3a1fbd2052654347f8912c34985a";
    sha256 = "11p16vsydc3kfx1nyhvsy4pxlqh9cnz6a9iz6pncx833c89qgrpj";
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
    url = "https://www.neilvandyke.org/racket/csv-reading.zip";
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
    rev = "e039c98941b3d272c6e462387df22846e10b0128";
    sha256 = "006bhdjkhn8bbi0p79ry5s0hvqi0mk2j5yzdllqrqpmclrw9bk5s";
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
    rev = "e039c98941b3d272c6e462387df22846e10b0128";
    sha256 = "006bhdjkhn8bbi0p79ry5s0hvqi0mk2j5yzdllqrqpmclrw9bk5s";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."scribble-lib" self."racket-doc" self."sandbox-lib" self."cur-lib" self."data-doc" ];
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
    rev = "e039c98941b3d272c6e462387df22846e10b0128";
    sha256 = "006bhdjkhn8bbi0p79ry5s0hvqi0mk2j5yzdllqrqpmclrw9bk5s";
  };
  };
  racketThinBuildInputs = [ self."base" self."turnstile-lib" self."macrotypes-lib" self."reprovide-lang-lib" ];
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
    rev = "e039c98941b3d272c6e462387df22846e10b0128";
    sha256 = "006bhdjkhn8bbi0p79ry5s0hvqi0mk2j5yzdllqrqpmclrw9bk5s";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."cur-lib" self."sweet-exp-lib" self."chk-lib" self."rackunit-macrotypes-lib" ];
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
    rev = "289e8cb903a24b2e1939a8556c164589a0e293e5";
    sha256 = "0v4ixk6wlmg3w90vxa5jphpgrnia25cs9www4vqmy9pg7n2mi2al";
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
    rev = "311df33cc83f67859ed9db8b236d227dec83d895";
    sha256 = "1w9j9kxf12jwb682d57adwpsnkmif101pgnz7a370fs93l8d4rv6";
  };
  racketThinBuildInputs = [ self."base" self."find-parent-dir" self."html-lib" self."markdown-ng" self."txexpr" self."racket-index" self."rackjure" self."reprovide-lang" self."scribble-lib" self."scribble-text-lib" self."srfi-lite-lib" self."web-server-lib" self."at-exp-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."scribble-text-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data" = self.lib.mkRacketDerivation rec {
  pname = "data";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/data.zip";
    sha1 = "293132f96206345435012f90598be62a46e9e258";
  };
  racketThinBuildInputs = [ self."data-lib" self."data-enumerate-lib" self."data-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-doc" = self.lib.mkRacketDerivation rec {
  pname = "data-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/data-doc.zip";
    sha1 = "fee7eb148057172461448355dbdab2e73d8ca76f";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."data-lib" self."data-enumerate-lib" self."scribble-lib" self."plot-lib" self."math-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "data-enumerate-lib" = self.lib.mkRacketDerivation rec {
  pname = "data-enumerate-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/data-enumerate-lib.zip";
    sha1 = "cbf55cf408239ae37354b45d871ced15c65991d0";
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
    rev = "dcbc48bc8ab7f1b9edb149f349e2c36ccd5ad722";
    sha256 = "0ns928hbxhmf4jldn0mqk7lk1rikmh3mvyjvp6salmhqgnb6xy7y";
  };
  racketThinBuildInputs = [ self."db-lib" self."draw-lib" self."math-lib" self."plot-gui-lib" self."plot-lib" self."srfi-lite-lib" self."typed-racket-lib" self."rackunit-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."db-doc" self."math-doc" self."plot-doc" self."al2-test-runner" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "data-lib" = self.lib.mkRacketDerivation rec {
  pname = "data-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/data-lib.zip";
    sha1 = "3788b6a3f6ffe527501ac0a20e6fdcfbfe18d834";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/data-test.zip";
    sha1 = "f8735e25fd4f6ff17f1962372e6d846d1e138c86";
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
    rev = "1bc45817ab41171da41d39c0027367eda698c463";
    sha256 = "0qcnn2xa2rgldgbp34yfkhjj839fx3jljh0qpd8wwn4famywqjgr";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/datalog.zip";
    sha1 = "78057119a3083eeecd5f4f57e27a11c4ce14dc24";
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
    rev = "5d865929dfcab856ebb85924ef16a74b13362662";
    sha256 = "185xnla5kqis9i2blxn6pvpkhm2aawlnkdlfinqyrp5hksrjz7zc";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db.zip";
    sha1 = "35dab81bb8153a8e02db29c93ec4db5ac07a6757";
  };
  racketThinBuildInputs = [ self."db-lib" self."db-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-doc" = self.lib.mkRacketDerivation rec {
  pname = "db-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-doc.zip";
    sha1 = "fbc840250fb5c424812082f94c0ca106c46e7397";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."srfi-lite-lib" self."base" self."scribble-lib" self."sandbox-lib" self."web-server-lib" self."db-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "db-lib" = self.lib.mkRacketDerivation rec {
  pname = "db-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-lib.zip";
    sha1 = "d66b5af0d125a41e16d0ae8a48c4a208d441fd24";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."unix-socket-lib" self."sasl-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "db-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-ppc-macosx.zip";
    sha1 = "6a33424c58812af873c8756fc78c3eabe8b16914";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-test" = self.lib.mkRacketDerivation rec {
  pname = "db-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-test.zip";
    sha1 = "3399fe4fba17a522638e08d6e656766a8821de0a";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."rackunit-lib" self."web-server-lib" self."srfi-lite-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "db-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-win32-i386.zip";
    sha1 = "7e703b3f271f299140c5d9d040af8b8ed6304d19";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "db-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-win32-x86_64.zip";
    sha1 = "d61946a43eea17f7ba7ea0ce455b3ca329d2138a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "db-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "db-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/db-x86_64-linux-natipkg.zip";
    sha1 = "1b7371c45f8f68bb8c0f4b5c89c78dac9884a582";
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
    rev = "50d2b35873e9d23b71387848ee35d214617650d2";
    sha256 = "125m6d99d3p2nsm12qd10f769zhmyzy8z9xd4fdwvvhkn5f45ckr";
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
    rev = "65ba96bcd64239358b2e1a95567c281a010c7e52";
    sha256 = "1lkgai63xinjv3ngdgznn64g7hmfixmcv1li7fgdsx32fbiy26i0";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "defensive-to-contracts" = self.lib.mkRacketDerivation rec {
  pname = "defensive-to-contracts";
  src = fetchgit {
    name = "defensive-to-contracts";
    url = "git://github.com/jiujiu1123/defensive-to-contracts.git";
    rev = "f64d8cb80a17fb981eb8269ef15f1fdb2f4d190b";
    sha256 = "0mvd6bvr183a2c25sflwnnh2k9qhgxd0q8x5vk4sl6y282afm9la";
  };
  racketThinBuildInputs = [ self."base" self."plai" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
  "define-who" = self.lib.mkRacketDerivation rec {
  pname = "define-who";
  src = fetchgit {
    name = "define-who";
    url = "git://github.com/sorawee/define-who.git";
    rev = "c77167fe7d5c2f3057cc80d9c201f9e888f02545";
    sha256 = "1cym8xc6qa3zf2sa3xkfmqm0rd1w6p6x9gjyib240wrfx2r826sk";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
  "define2" = self.lib.mkRacketDerivation rec {
  pname = "define2";
  src = fetchgit {
    name = "define2";
    url = "git://github.com/Metaxal/define2.git";
    rev = "c9760f29b27e45c6fa9edee37d6275214745e8f8";
    sha256 = "1szgf882wa77pqv54n9vqkfp5c4jyq7mb6p7wc68khvqy81a43zl";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/deinprogramm.zip";
    sha1 = "63de7b717e785dd799b451f61972b872391fbb81";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."deinprogramm-signature" self."drracket" self."drracket-plugin-lib" self."errortrace-lib" self."gui-lib" self."htdp-lib" self."pconvert-lib" self."scheme-lib" self."string-constants-lib" self."trace" self."wxme-lib" self."at-exp-lib" self."htdp-doc" self."racket-doc" self."racket-index" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "deinprogramm-signature" = self.lib.mkRacketDerivation rec {
  pname = "deinprogramm-signature";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/deinprogramm-signature.zip";
    sha1 = "cf4f59ce92ad9731526b2f5ce7090dcca4ea5458";
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
    rev = "19541b8094b1aac23268f13d308202627275a360";
    sha256 = "1y3dg6p5657nw6mxwb34yd16y41mb4z71cjhjxs7djw302j6f2ym";
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
    rev = "e694813d9540623a04cbff78034502c2a693e90a";
    sha256 = "1hp105f0vjg5z3h59qs5s2iv22nr6iswak5y8410l4al80cjvj79";
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
    rev = "876afa49eebf64b22cdaafd9ec284a4d4a8af6de";
    sha256 = "1zln1f6ha4ii27pgh4y0d538gf0x6f72057fpcnkfpaxhbvkcmq8";
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
    rev = "876afa49eebf64b22cdaafd9ec284a4d4a8af6de";
    sha256 = "1zln1f6ha4ii27pgh4y0d538gf0x6f72057fpcnkfpaxhbvkcmq8";
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
    rev = "876afa49eebf64b22cdaafd9ec284a4d4a8af6de";
    sha256 = "1zln1f6ha4ii27pgh4y0d538gf0x6f72057fpcnkfpaxhbvkcmq8";
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
    rev = "876afa49eebf64b22cdaafd9ec284a4d4a8af6de";
    sha256 = "1zln1f6ha4ii27pgh4y0d538gf0x6f72057fpcnkfpaxhbvkcmq8";
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
    rev = "5d4d2b765bfdfb0335c1a13a897a8bb3e65d85f9";
    sha256 = "1d395k30gjvljccwy084z2j04x0vybxd4lxfg2ah55wvxi8cvhqi";
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
    rev = "99f06659f3f7659dc577df4fef1d2b6f6eb12baa";
    sha256 = "0crzmj2i4bqpcr821di5k6zarcm7ppqn8p86xzyiiv2aqhsf9zzn";
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
    rev = "aec2dfeada8cb719bd9439096ecf711d5a068e60";
    sha256 = "1nrzgqlf0932i8ijisjv8ancvmd1cmfsdz8w8vlh4nf4vknylmjc";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."typed-racket-lib" self."typed-racket-more" self."racket-index" self."sandbox-lib" self."scribble-lib" self."math-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "disassemble" = self.lib.mkRacketDerivation rec {
  pname = "disassemble";
  src = fetchgit {
    name = "disassemble";
    url = "git://github.com/samth/disassemble.git";
    rev = "c4f80cd7994d2d4f9ad4aae0734c454d33390017";
    sha256 = "049r1hzgaiil6dwj667klpgfbd3c7agsns44qs7rbndy48qbxf2s";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distributed-places.zip";
    sha1 = "1f41084ea43dedfaca060331b13380aa5e5c8164";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."distributed-places-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places-doc" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distributed-places-doc.zip";
    sha1 = "f50f9db15d44c538801c625471146037c824e770";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."distributed-places-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "distributed-places-lib" = self.lib.mkRacketDerivation rec {
  pname = "distributed-places-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distributed-places-lib.zip";
    sha1 = "5bca828d25f9bdfedb67f349547b208141adb791";
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
    rev = "080f8ccb9b1007a07ac2da25e12d75f18e799eb5";
    sha256 = "0gbn926lyp0x9cq651nh16vigb027dyvqnpcz09xx5iyf3i2vdhr";
  };
  };
  racketThinBuildInputs = [ self."distro-build-lib" self."distro-build-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-client" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-client";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distro-build-client.zip";
    sha1 = "911b2569651b03c0027ec6e5f2160c7cff024a07";
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
    rev = "080f8ccb9b1007a07ac2da25e12d75f18e799eb5";
    sha256 = "0gbn926lyp0x9cq651nh16vigb027dyvqnpcz09xx5iyf3i2vdhr";
  };
  };
  racketThinBuildInputs = [ self."base" self."distro-build-server" self."distro-build-client" self."web-server-lib" self."at-exp-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-lib" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distro-build-lib.zip";
    sha1 = "e947b8c0736b05ae2be7cf2c86837a4bccb0aec3";
  };
  racketThinBuildInputs = [ self."distro-build-client" self."distro-build-server" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "distro-build-server" = self.lib.mkRacketDerivation rec {
  pname = "distro-build-server";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/distro-build-server.zip";
    sha1 = "101ac845cfdfa38f2612bcb318d8acc648f4b247";
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
    rev = "080f8ccb9b1007a07ac2da25e12d75f18e799eb5";
    sha256 = "0gbn926lyp0x9cq651nh16vigb027dyvqnpcz09xx5iyf3i2vdhr";
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
    rev = "b1c0e9f3fd3a25e260f8905e6c8211dacf532b25";
    sha256 = "07zxvfwgr0a6nx2l5jrda2785lfr6ncamalhaz041hlvh5s2q909";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."rackunit-lib" self."reprovide-lang-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "dollar" = self.lib.mkRacketDerivation rec {
  pname = "dollar";
  src = fetchgit {
    name = "dollar";
    url = "git://github.com/rogerkeays/racket-dollar.git";
    rev = "16fa7aec4e1cef43a7b678dc798b1a9c20a87bb6";
    sha256 = "0s3bfz2w3dsq9qjnppzf9lk6nn7nxdiv4grk7xrmnpvlmfsczxc2";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" ];
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
    rev = "96cfe93ab611db377a4a68f4b0a7e483ebf506a6";
    sha256 = "1hijk9gvrpnpb9cdbwvnjdibxpj14ih59k40c9wpddnpqszp7xfw";
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
    url = "git://github.com/dracula/racket.git";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw.zip";
    sha1 = "3db3d94d453f89e9c697f3e2a03ac76b439d994d";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."draw-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-aarch64-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "draw-aarch64-macosx-3";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/84ff2482fae3acffb0992f4b9a9000b97ef09c10/draw-aarch64-macosx-3.zip";
    sha1 = "84ff2482fae3acffb0992f4b9a9000b97ef09c10";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-doc" = self.lib.mkRacketDerivation rec {
  pname = "draw-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-doc.zip";
    sha1 = "1165f7a74819122542bab364e7e4a52b27963821";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-i386-macosx-3.zip";
    sha1 = "f230aa020702ee37b24be7d84f76ec830b330c1a";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-lib" = self.lib.mkRacketDerivation rec {
  pname = "draw-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-lib.zip";
    sha1 = "d31da9fb950bc0404e5466549d46d6a25c378b3d";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-ppc-macosx-3.zip";
    sha1 = "cdc595aa13507b198ae5a5205a12ae69ed4632ef";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-test" = self.lib.mkRacketDerivation rec {
  pname = "draw-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-test.zip";
    sha1 = "ddbe2f24e14eb1b2dc0a4a1f179cde574c1613a4";
  };
  racketThinBuildInputs = [ self."base" self."racket-index" self."scheme-lib" self."draw-lib" self."racket-test" self."sgl" self."gui-lib" self."rackunit-lib" self."pconvert-lib" self."compatibility-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-ttf-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "draw-ttf-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-ttf-x86_64-linux-natipkg.zip";
    sha1 = "16679ea395da18bf30699f4ecd1c12b219f651c2";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-win32-i386-3.zip";
    sha1 = "2cf4e8f7458bbb143e66a3461b43aef4cea7ff3c";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-win32-x86_64-3.zip";
    sha1 = "c5cfa9c5c100bd5bff8b47a3f99aecc07c854116";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "draw-x11-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "draw-x11-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-x11-x86_64-linux-natipkg.zip";
    sha1 = "54f8702a83966999bf0b061014543a4ce92c6f2c";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-x86_64-linux-natipkg-3.zip";
    sha1 = "4d918fb36d0da983fca3adaf8463c5c326828412";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/draw-x86_64-macosx-3.zip";
    sha1 = "8120671d18d663a96140b074a67d76f06f2a6e25";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."srfi-lib" self."drcomplete-base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drcomplete-method-names" = self.lib.mkRacketDerivation rec {
  pname = "drcomplete-method-names";
  src = self.lib.extractPath {
    path = "drcomplete-method-names";
    src = fetchgit {
    name = "drcomplete-method-names";
    url = "git://github.com/yjqww6/drcomplete.git";
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
  };
  };
  racketThinBuildInputs = [ self."base" self."drracket-plugin-lib" self."gui-lib" self."drcomplete-base" self."rackunit-lib" ];
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "fead5ffb7e8eadae5cbddb6ca44f173ec155ade8";
    sha256 = "01f3gw881sgaiw87w9jbalayaz4gk1knfgg3jb7mjc1r60pcpb7y";
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
    rev = "a3e5e778a1c19e7312b98bab25ed95075783f896";
    sha256 = "0wskjnn13axr735hzb99m9y1y272nwq20bgvsx2rdjdgq1yhfsaz";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket.zip";
    sha1 = "9ad972b8c8527889dba7effc8e7f09065852c0c0";
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
  "drracket-cmdline-args" = self.lib.mkRacketDerivation rec {
  pname = "drracket-cmdline-args";
  src = fetchgit {
    name = "drracket-cmdline-args";
    url = "git://github.com/sorawee/drracket-cmdline-args.git";
    rev = "d0b3806a1ebd38dad22cac27b479ab7254a5bf33";
    sha256 = "0q1w3la91lgkjf9s34ihp3kvaggsnaly5dmm67875qh3ccks9amr";
  };
  racketThinBuildInputs = [ self."drracket-plugin-lib" self."gui-lib" self."shlex" self."base" self."scribble-lib" self."racket-doc" ];
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
  "drracket-one-dark" = self.lib.mkRacketDerivation rec {
  pname = "drracket-one-dark";
  src = fetchgit {
    name = "drracket-one-dark";
    url = "git://github.com/JoaoBrlt/drracket-one-dark.git";
    rev = "7b9dbd998e8976f37f98cf1f8fa25c4f4631dcef";
    sha256 = "0clspvq4isg1xhca5cq9i4a3kjhpndydalck66yj30xivlp19p19";
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
    rev = "b2272896fcdba7e1f2fae7f0f3ecf0043252a10f";
    sha256 = "1izlli2qh41vfjim8938fwlwd0f8by9fxaxlli53j7x45fg5gnf3";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."gui-lib" self."srfi-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-plugin-lib" = self.lib.mkRacketDerivation rec {
  pname = "drracket-plugin-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-plugin-lib.zip";
    sha1 = "f52930320066b5f89db079428e119e6bc693f987";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-restore-workspace" = self.lib.mkRacketDerivation rec {
  pname = "drracket-restore-workspace";
  src = fetchgit {
    name = "drracket-restore-workspace";
    url = "git://github.com/sorawee/drracket-restore-workspace.git";
    rev = "76a7f64331fc2a85f0c26f1465cf0ce07a8a3fad";
    sha256 = "1alzyiyg5q3660pdkhig5gdjd5ws26msk7512lw88jagar0g2dhd";
  };
  racketThinBuildInputs = [ self."drracket-plugin-lib" self."gui-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-scheme-dark-green" = self.lib.mkRacketDerivation rec {
  pname = "drracket-scheme-dark-green";
  src = fetchgit {
    name = "drracket-scheme-dark-green";
    url = "git://github.com/shhyou/drracket-scheme-dark-green.git";
    rev = "bda60667005f146ffa78b6435e10cd5731d7f211";
    sha256 = "1g2wxngs0rf28gkrhw4lx9ij1wi6l2gr8nirfcsizjc72fmw7ysv";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-test.zip";
    sha1 = "4e331a89b40eaa3580610ecf91df91bc45bbac97";
  };
  racketThinBuildInputs = [ self."base" self."htdp" self."drracket" self."racket-index" self."scheme-lib" self."at-exp-lib" self."rackunit-lib" self."compatibility-lib" self."gui-lib" self."htdp" self."compiler-lib" self."cext-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-tool.zip";
    sha1 = "9264cabd59d0cdd7f0adf2e88b757acb4ac43c08";
  };
  racketThinBuildInputs = [ self."drracket-tool-lib" self."drracket-tool-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-doc" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-tool-doc.zip";
    sha1 = "4110be53d8db7658988679f3f4926091bd34531a";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scribble-lib" self."drracket-tool-lib" self."gui-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-lib" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-tool-lib.zip";
    sha1 = "0f314f55645ce66387344118637e1a813e206957";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."string-constants-lib" self."scribble-lib" self."racket-index" self."gui-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "drracket-tool-test" = self.lib.mkRacketDerivation rec {
  pname = "drracket-tool-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/drracket-tool-test.zip";
    sha1 = "381d0282995d2242525f9a387d95ba57bb8076d6";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/ds-store.zip";
    sha1 = "60caa0d2174c63e666cc85a654bae30d0445535b";
  };
  racketThinBuildInputs = [ self."ds-store-lib" self."ds-store-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ds-store-doc" = self.lib.mkRacketDerivation rec {
  pname = "ds-store-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/ds-store-doc.zip";
    sha1 = "2ce0aefe599be51a3849468d75efdc7bd5342a1a";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."ds-store-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "ds-store-lib" = self.lib.mkRacketDerivation rec {
  pname = "ds-store-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/ds-store-lib.zip";
    sha1 = "e49d6eaa4ce064be81d10f4b569e2cb175359a36";
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
    rev = "105d18069465781bd9b87466f8336d5ce9e9a0f3";
    sha256 = "15mj2dpbm5ggz62k3b8jr17by2svl86fcn7kjfy8zjz0jai468nw";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."rackunit-lib" self."parser-tools-lib" self."plot-gui-lib" self."plot-lib" self."sandbox-lib" self."snip-lib" self."scribble-lib" self."racket-doc" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/dynext-lib.zip";
    sha1 = "7d7254a2a28182c5877d9e1ca49eaebdc3debd5c";
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
  "ec" = self.lib.mkRacketDerivation rec {
  pname = "ec";
  src = fetchgit {
    name = "ec";
    url = "git://github.com/marckn0x/ec.git";
    rev = "81d6fbe1852d3b20cffa651e6062dd1aca146018";
    sha256 = "086qvya172xkikp4ac00jqqbf43capj45vf7z9b5imy5099d0vv5";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."binaryio" self."typed-racket-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."crypto-lib" self."rackunit-typed" ];
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
    rev = "10f3dfe3b0a0ecd646de11cbbf706e8028a989b2";
    sha256 = "13pw2b5i5zvxiizb96w53y92i104jffz8v0f11qpffv6ybr98p7a";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "eff" = self.lib.mkRacketDerivation rec {
  pname = "eff";
  src = fetchgit {
    name = "eff";
    url = "git://github.com/syntacticlosure/eff.git";
    rev = "1c467f8f4f79706c3fcd5b4e429f74bcb2c7eaa7";
    sha256 = "06y0w8bxicp921iyivpcp94zbgjifpyd08yz6nbfq6kgzy16c1xr";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
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
    rev = "f63023df2e26612f860f07693ae80a0ffd057c1e";
    sha256 = "1zrqb33h533n0fjpjwhhsgybas8n5bg5vlam8yqc0b2b84ki5m1w";
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
    rev = "f63023df2e26612f860f07693ae80a0ffd057c1e";
    sha256 = "1zrqb33h533n0fjpjwhhsgybas8n5bg5vlam8yqc0b2b84ki5m1w";
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
    rev = "f63023df2e26612f860f07693ae80a0ffd057c1e";
    sha256 = "1zrqb33h533n0fjpjwhhsgybas8n5bg5vlam8yqc0b2b84ki5m1w";
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
    rev = "f63023df2e26612f860f07693ae80a0ffd057c1e";
    sha256 = "1zrqb33h533n0fjpjwhhsgybas8n5bg5vlam8yqc0b2b84ki5m1w";
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
  "egg-herbie" = self.lib.mkRacketDerivation rec {
  pname = "egg-herbie";
  src = fetchgit {
    name = "egg-herbie";
    url = "git://github.com/herbie-fp/egg-herbie.git";
    rev = "edeee228439c6ffa5f24cc5b4cd23ddf1e2a0039";
    sha256 = "0mm616fraihla2spkw1x32axl95wgs7n9ghwzc77zq82n8r0z66h";
  };
  racketThinBuildInputs = [ self."egg-herbie-windows" self."egg-herbie-osx" self."egg-herbie-linux" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "egg-herbie-linux" = self.lib.mkRacketDerivation rec {
  pname = "egg-herbie-linux";
  src = fetchgit {
    name = "egg-herbie-linux";
    url = "git://github.com/herbie-fp/egg-herbie.git";
    rev = "d42993194c2f8d7bbdd303959e17f816e058096e";
    sha256 = "1d6zsy537dd11pk09l4qsmc1dz4yrg4xfyp89paz4mydn2483gwg";
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
    rev = "f86c59cbb8a30c616e96d74cf29c26c4c329674e";
    sha256 = "08zip4kmcjgx2qzq4zcgc9g2h1m2ghvfcng5qda9ag1hs4f8zfb0";
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
    rev = "c54bde206b82671cbb2ef262504b63cf2fa131e5";
    sha256 = "06aya6zb5r1majc6bqy07nwvbkfjdc28sifp38cq62bv20fniy2i";
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
    rev = "52d5acb0339dc38a6410f853957d57f90f566131";
    sha256 = "1h9vh4iqs13varvfkzf2l52m68qg1c5jcgfpb60w5dn6jxd16ypq";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/eli-tester.zip";
    sha1 = "bcd57f5bffdbcc55bb863e7ebb7bbf743f23e844";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "elle" = self.lib.mkRacketDerivation rec {
  pname = "elle";
  src = self.lib.extractPath {
    path = "elle";
    src = fetchgit {
    name = "elle";
    url = "git://github.com/tail-reversion/elle.git";
    rev = "87053a6ba8e12c15823395149fe74a62ebb77fee";
    sha256 = "0hz0g07v1s40iajjzrs81w44i2nkf1g5x49qxcnc31vzbcr7kg6j";
  };
  };
  racketThinBuildInputs = [ self."elle-lib" self."elle-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "elle-doc" = self.lib.mkRacketDerivation rec {
  pname = "elle-doc";
  src = self.lib.extractPath {
    path = "elle-doc";
    src = fetchgit {
    name = "elle-doc";
    url = "git://github.com/tail-reversion/elle.git";
    rev = "87053a6ba8e12c15823395149fe74a62ebb77fee";
    sha256 = "0hz0g07v1s40iajjzrs81w44i2nkf1g5x49qxcnc31vzbcr7kg6j";
  };
  };
  racketThinBuildInputs = [ self."base" self."elle-lib" self."scribble-lib" self."racket-doc" self."rebellion" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "elle-lib" = self.lib.mkRacketDerivation rec {
  pname = "elle-lib";
  src = self.lib.extractPath {
    path = "elle-lib";
    src = fetchgit {
    name = "elle-lib";
    url = "git://github.com/tail-reversion/elle.git";
    rev = "87053a6ba8e12c15823395149fe74a62ebb77fee";
    sha256 = "0hz0g07v1s40iajjzrs81w44i2nkf1g5x49qxcnc31vzbcr7kg6j";
  };
  };
  racketThinBuildInputs = [ self."base" self."rebellion" ];
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
  "envlang" = self.lib.mkRacketDerivation rec {
  pname = "envlang";
  src = fetchgit {
    name = "envlang";
    url = "git://github.com/envlang/racket.git";
    rev = "c45bfb25492a5fbedad50c7ad530d82bbbb43e3c";
    sha256 = "15qc4d6v4avvq8cy7d2b567k5gdxzkswgyw8sfl8jrdbzl57hm5c";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."phc-toolkit" self."base" self."reprovide-lang-lib" self."polysemy" self."scribble-lib" self."hyper-literate" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/eopl.zip";
    sha1 = "c9db46760df222e69a5c6005b804c66dd93ceb10";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace" = self.lib.mkRacketDerivation rec {
  pname = "errortrace";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/errortrace.zip";
    sha1 = "0b6c18099df60fc3b325f111001161b059003973";
  };
  racketThinBuildInputs = [ self."errortrace-lib" self."errortrace-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-doc" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/errortrace-doc.zip";
    sha1 = "38818a9352fa569148eaa5e977c7a36b198bf367";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."errortrace-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-lib" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/errortrace-lib.zip";
    sha1 = "d78cda1e4539b2ebca52e01a0e52d1de8bb8881d";
  };
  racketThinBuildInputs = [ self."base" self."source-syntax" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-pkg" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-pkg";
  src = fetchgit {
    name = "errortrace-pkg";
    url = "git://github.com/sorawee/errortrace-pkg.git";
    rev = "cb7038eb6b7200ed44b75d45bbab66bb836232ec";
    sha256 = "11ag6ifnnpadj8ynrg4grqbvzzds4k64yjalr5xp0in8flcip4pj";
  };
  racketThinBuildInputs = [ self."base" self."custom-load" self."errortrace-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "errortrace-test" = self.lib.mkRacketDerivation rec {
  pname = "errortrace-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/errortrace-test.zip";
    sha1 = "e2ab49ed3847a9bedb468220be7fba1196f02d2e";
  };
  racketThinBuildInputs = [ self."errortrace-lib" self."eli-tester" self."rackunit-lib" self."base" self."racket-index" self."compiler-lib" self."at-exp-lib" ];
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
  "event" = self.lib.mkRacketDerivation rec {
  pname = "event";
  src = fetchgit {
    name = "event";
    url = "git://github.com/dedbox/racket-event.git";
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
    rev = "922bab40b54930a13b8609ee28f3362f5ce1a95f";
    sha256 = "0j9yr85a0a81d7d078jkkmgs2w6isksz7hl6g66567xfprp70fbc";
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
  "extenor" = self.lib.mkRacketDerivation rec {
  pname = "extenor";
  src = fetchgit {
    name = "extenor";
    url = "git://github.com/willghatch/racket-extenor.git";
    rev = "6be463cb23ceca3b602ce1c482cd6d37cd7a6e15";
    sha256 = "1g2b45x2975cyrc9xwrfa1vjmgqll2h1iwyqgp3xh4pv4imrjzmv";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
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
    rev = "616130a74b83cf7790257150655949698a7a3913";
    sha256 = "1gf9g2a4ncn3xj3q26r6n15hg9qmmw2dsld16qii6ybphbdxdpzw";
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
    rev = "31ddeb91625dd6f95002c47e670751dd16704524";
    sha256 = "02gc775v32kj85gyya40ni27xxv1zndr8fbdwdz2x4m8l37qfl3j";
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
  "fast-sequence" = self.lib.mkRacketDerivation rec {
  pname = "fast-sequence";
  src = self.lib.extractPath {
    path = "fast-sequence";
    src = fetchgit {
    name = "fast-sequence";
    url = "git://github.com/abolotina/fast-sequence-combinators.git";
    rev = "d5144e2d6f73f441937a77439f80b79000768cd9";
    sha256 = "0khwx4i0q4g02jfcaa5sc05yjpzhhsjpsrfm8yj0ifzdbjyngy5r";
  };
  };
  racketThinBuildInputs = [ self."base" self."fast-sequence-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fast-sequence-lib" = self.lib.mkRacketDerivation rec {
  pname = "fast-sequence-lib";
  src = self.lib.extractPath {
    path = "fast-sequence-lib";
    src = fetchgit {
    name = "fast-sequence-lib";
    url = "git://github.com/abolotina/fast-sequence-combinators.git";
    rev = "d5144e2d6f73f441937a77439f80b79000768cd9";
    sha256 = "0khwx4i0q4g02jfcaa5sc05yjpzhhsjpsrfm8yj0ifzdbjyngy5r";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "faster-minikanren" = self.lib.mkRacketDerivation rec {
  pname = "faster-minikanren";
  src = fetchgit {
    name = "faster-minikanren";
    url = "git://github.com/michaelballantyne/faster-miniKanren.git";
    rev = "d6c763ef445d80dc7a9eab5be6c63fc2d8fdd4b1";
    sha256 = "1l9p4n0g1zwv66j1sk09isa14i1bnsh5zkqzws0xr9csmp8xwxvq";
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
    rev = "c2ea40456784fa45d682bc4230b49e07f862ae78";
    sha256 = "0pd8bfdklcwk4jwiq46iaq3k5r0lxf9zgmvcbjds01saci8abxx8";
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
    rev = "c1ac766a345a335438165ab0d13a4d8f6aec6162";
    sha256 = "0b5mn98q94a1d8w7vjxb0ywn2sd43cgk9422104hrnaxiymhxizl";
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
    rev = "5a1016894db4795c25684c817326f28fa788d196";
    sha256 = "13skjkjpfbq2xczap4ldcmw6z1cl7x04kd19c3syqini6xb6fykw";
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
  "fltest" = self.lib.mkRacketDerivation rec {
  pname = "fltest";
  src = fetchgit {
    name = "fltest";
    url = "git://github.com/samth/fltest.git";
    rev = "8d2d686a7d940accf540b74a9409d3b51ea980eb";
    sha256 = "1ckk3wsgml18fxdmnd3iy6bpkln9rw6r28mmjc21k1jr13h4avzs";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "fluent" = self.lib.mkRacketDerivation rec {
  pname = "fluent";
  src = fetchgit {
    name = "fluent";
    url = "git://github.com/rogerkeays/racket-fluent.git";
    rev = "b8bc82e25a35451ba3136f393157e380e6f4837f";
    sha256 = "03rl75gs15avnp1gpwhi8ni4n7qsq3z2ibgbzdpp6yfq2br53fs0";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" ];
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
    rev = "e50e4c82f58e2014d64e87a14c1d29b546fb393b";
    sha256 = "0g0ayqf3pa3f5xv6lw0yxldccb6ryhw7dpxw2yhlw54w89svjd40";
  };
  racketThinBuildInputs = [ self."crc32c" self."db-lib" self."base" self."beautiful-racket-lib" self."debug" self."draw-lib" self."rackunit-lib" self."png-image" self."sugar" self."xenomorph" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "for-helpers" = self.lib.mkRacketDerivation rec {
  pname = "for-helpers";
  src = fetchgit {
    name = "for-helpers";
    url = "git://github.com/yjqww6/for-helpers.git";
    rev = "3753dbce905e5c115e8107a9411249a12a06fd64";
    sha256 = "1ys4x7b4ddqj42ncdsmaa2bys8rbfkjk4g2p9j4s9qph1i37plkh";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "forge" = self.lib.mkRacketDerivation rec {
  pname = "forge";
  src = self.lib.extractPath {
    path = "forge";
    src = fetchgit {
    name = "forge";
    url = "git://github.com/tnelson/Forge.git";
    rev = "bdc2d9a9c7149eb91bba56a1c7d4c9c078decc53";
    sha256 = "09dlbqdihshaqq9m2kci3yf954dx7dwgjzywhh24qnsdahll6d4h";
  };
  };
  racketThinBuildInputs = [ self."base" self."syntax-classes" self."br-parser-tools-lib" self."brag-lib" self."beautiful-racket" self."syntax-color-lib" self."net-lib" self."profile-lib" self."crypto-lib" self."rackunit-lib" self."web-server-lib" self."mischief" self."gui-lib" self."drracket-plugin-lib" self."pretty-format" self."predicates" self."basedir" self."request" self."sha" ];
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
    rev = "80e6dee1184ab4c435678bb3c45fa11bfabf56ee";
    sha256 = "13q8v332chmd0qscrk7wim9c66s5vxhzyhg7nl9g25b8sa96z4j4";
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
    rev = "80e6dee1184ab4c435678bb3c45fa11bfabf56ee";
    sha256 = "13q8v332chmd0qscrk7wim9c66s5vxhzyhg7nl9g25b8sa96z4j4";
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
    rev = "80e6dee1184ab4c435678bb3c45fa11bfabf56ee";
    sha256 = "13q8v332chmd0qscrk7wim9c66s5vxhzyhg7nl9g25b8sa96z4j4";
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
    rev = "80e6dee1184ab4c435678bb3c45fa11bfabf56ee";
    sha256 = "13q8v332chmd0qscrk7wim9c66s5vxhzyhg7nl9g25b8sa96z4j4";
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
    rev = "3143f5d46ed1a40908b184ba5cb5c7d4e09fbf77";
    sha256 = "0sfrdqnnbk3wi0pbc1lfwl503284ynh8x9pjbfx4r6a78p6ivj00";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."generic-flonum" self."rackunit-lib" ];
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
    rev = "93d8b442c2e619334612b7e2d091e4eb33995021";
    sha256 = "0rgjc9m45298fgbk26jszwwhb81lwmqw0nm1039abasc2prvsqaa";
  };
  racketThinBuildInputs = [ self."base" self."find-parent-dir" self."html-lib" self."markdown" self."racket-index" self."reprovide-lang" self."scribble-lib" self."scribble-text-lib" self."srfi-lite-lib" self."threading-lib" self."web-server-lib" self."at-exp-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-doc" self."scribble-text-lib" self."threading-doc" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "from-template" = self.lib.mkRacketDerivation rec {
  pname = "from-template";
  src = fetchgit {
    name = "from-template";
    url = "git://github.com/nixin72/from-template.git";
    rev = "921d1ea4bc6ca1d523c3af548d2fdb7ac5046970";
    sha256 = "0115cc3mf7l709mmjpgmn8spjw0yy06b62gvibhm18wv1bha9r66";
  };
  racketThinBuildInputs = [ self."base" self."readline" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "frtime" = self.lib.mkRacketDerivation rec {
  pname = "frtime";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/frtime.zip";
    sha1 = "018967c117669136bc0947dbf9f23742b984500a";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/future-visualizer.zip";
    sha1 = "5b657b32add62f94e029da849b7a2bbe530cf50b";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."data-lib" self."draw-lib" self."pict-lib" self."gui-lib" self."future-visualizer-pict" self."scheme-lib" self."scribble-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "future-visualizer-pict" = self.lib.mkRacketDerivation rec {
  pname = "future-visualizer-pict";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/future-visualizer-pict.zip";
    sha1 = "1c8c94c9b0a4589cd53810d68e8d933b2172afc6";
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."draw-lib" self."pict-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "future-visualizer-typed" = self.lib.mkRacketDerivation rec {
  pname = "future-visualizer-typed";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/future-visualizer-typed.zip";
    sha1 = "ea8f8298d07f9c89189b5c82e2917d85b5786402";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/games.zip";
    sha1 = "7c53a47353bf81161790390afaa5566875cd77af";
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
    rev = "0ff9a1934f4421c53ec4b71cb48d54a6ad86c7b9";
    sha256 = "0p5gfb2frd70d3gn1ipl8aqqamr04h8jjpj5w9ir3qrgww2ybbxh";
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
    rev = "13c856ba90be7dc3857f7b9471501d859666537e";
    sha256 = "0qmjks83gskqijf6wr4g64gnyi7j6wdjx266iq2624mjjxcn2nk5";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."relation" self."social-contract" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."cover" self."cover-coveralls" self."collections-doc" ];
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
  "generic-flonum" = self.lib.mkRacketDerivation rec {
  pname = "generic-flonum";
  src = fetchgit {
    name = "generic-flonum";
    url = "git://github.com/bksaiki/generic-flonum.git";
    rev = "05347d11e59954bf0001064b965db90b29047eee";
    sha256 = "1912izkb1l7jy6haq1vmv1s3mi6nccvi318yma9xra5kwgjp4rc1";
  };
  racketThinBuildInputs = [ self."math-lib" self."base" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."math-doc" ];
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
  "geoid" = self.lib.mkRacketDerivation rec {
  pname = "geoid";
  src = fetchgit {
    name = "geoid";
    url = "git://github.com/alex-hhh/geoid.git";
    rev = "eb04d4c736d4b17e4095dbba89e25cac3ab7ab60";
    sha256 = "1sh8qla059jbxwr19395rd8n1rsq9jaaxaqdyng31lrl2nq1gzyx";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."rackunit-lib" self."typed-racket-lib" self."racket-doc" self."scribble-lib" self."al2-test-runner" ];
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
    rev = "2ae1a01915b71dc6e0ea0afa384d55e8e14ead4e";
    sha256 = "0bg20yz4yzmqnmbsif5dnvgn6j6129lnpi8c94069iv69qrfw72z";
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
    rev = "2ae1a01915b71dc6e0ea0afa384d55e8e14ead4e";
    sha256 = "0bg20yz4yzmqnmbsif5dnvgn6j6129lnpi8c94069iv69qrfw72z";
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
    rev = "2ae1a01915b71dc6e0ea0afa384d55e8e14ead4e";
    sha256 = "0bg20yz4yzmqnmbsif5dnvgn6j6129lnpi8c94069iv69qrfw72z";
  };
  };
  racketThinBuildInputs = [ self."base" self."net-ip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "get-bonus" = self.lib.mkRacketDerivation rec {
  pname = "get-bonus";
  src = fetchgit {
    name = "get-bonus";
    url = "git://github.com/get-bonus/get-bonus.git";
    rev = "d9bb88d2940263641c35ad98912c5a2b3136cc96";
    sha256 = "1aq8b9afa25cwmjqv17da7j1nq9x3xa99cvcbgyls1gz1ww2nh3v";
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
    rev = "6733b1094c57bb9d6e1e5e4a415fd4e2d0878d99";
    sha256 = "1j2fmb723mifgmn85fqr67z3iyfm1lb5nw2a78qqva6h19r1vdn7";
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
  "glass" = self.lib.mkRacketDerivation rec {
  pname = "glass";
  src = fetchgit {
    name = "glass";
    url = "git://github.com/jackfirth/glass.git";
    rev = "a5b25ed7716598b49ccdb5b6917d0eacd95764cf";
    sha256 = "14gkhwfxwg9yhf76pzb016j9xqm1bf05b4lg4dzyybnd8wl1hn2z";
  };
  racketThinBuildInputs = [ self."base" self."fancy-app" self."rebellion" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "glc" = self.lib.mkRacketDerivation rec {
  pname = "glc";
  src = fetchgit {
    name = "glc";
    url = "git://github.com/GriffinMB/glc.git";
    rev = "22fd96aa0a11b092cd8aaaeb049e03bea05764d3";
    sha256 = "1n4x9lcdg1glvyy8z73yipmvqv5rk5m3045ypfp8xglmb9zshfny";
  };
  racketThinBuildInputs = [ self."lazy" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
  "global" = self.lib.mkRacketDerivation rec {
  pname = "global";
  src = fetchgit {
    name = "global";
    url = "git://github.com/Metaxal/global.git";
    rev = "d912b774228e449f19083cba15e37b188a1673b4";
    sha256 = "05kwq2vap5fkpvx80jd1njhyp6nwypp2hrlbwrpx6p9y5f02xy0d";
  };
  racketThinBuildInputs = [ self."text-table" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "768c33615a1c2414ccaf1a1e4ea1064bd5dd46af";
    sha256 = "0iblwasvvmcsc0kn0f3zcijgiiz56jz1g8shww2kr7zs81v5hkv7";
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
    rev = "768c33615a1c2414ccaf1a1e4ea1064bd5dd46af";
    sha256 = "0iblwasvvmcsc0kn0f3zcijgiiz56jz1g8shww2kr7zs81v5hkv7";
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
    rev = "701dee030a70b778f6de9dae428d6287aecd7a5a";
    sha256 = "13k28wd2b3r21k57rixdypa198v69vzxkc88hdhl63iskim5l1j0";
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
    rev = "aa17ae4d08582eaa7b2d999edc940b9076d9fac5";
    sha256 = "0rb064s0wy0wj4cp43g4w3glqf8dgvx66glplyb46x7g76gmlyvy";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto" self."syrup" self."pk" self."rackunit-lib" self."scribble-lib" self."sandbox-lib" self."racket-doc" ];
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
    rev = "63567f8f380ca2bc908ec11d9f9c7d856b8ab3bf";
    sha256 = "0w0f0srdjjxbfw2brvp0zf3ys2g8vga7896jcprnd0m5p5aakihm";
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
    rev = "0ff9a1934f4421c53ec4b71cb48d54a6ad86c7b9";
    sha256 = "0p5gfb2frd70d3gn1ipl8aqqamr04h8jjpj5w9ir3qrgww2ybbxh";
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
    rev = "0ff9a1934f4421c53ec4b71cb48d54a6ad86c7b9";
    sha256 = "0p5gfb2frd70d3gn1ipl8aqqamr04h8jjpj5w9ir3qrgww2ybbxh";
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
    rev = "0ff9a1934f4421c53ec4b71cb48d54a6ad86c7b9";
    sha256 = "0p5gfb2frd70d3gn1ipl8aqqamr04h8jjpj5w9ir3qrgww2ybbxh";
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
    rev = "0ff9a1934f4421c53ec4b71cb48d54a6ad86c7b9";
    sha256 = "0p5gfb2frd70d3gn1ipl8aqqamr04h8jjpj5w9ir3qrgww2ybbxh";
  };
  };
  racketThinBuildInputs = [ self."base" self."graph-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graphic-block" = self.lib.mkRacketDerivation rec {
  pname = "graphic-block";
  src = self.lib.extractPath {
    path = "graphic-block";
    src = fetchgit {
    name = "graphic-block";
    url = "git://github.com/djh-uwaterloo/uwaterloo-racket.git";
    rev = "24f1c0034ea24180c4d501eb51efd96f5f349215";
    sha256 = "0s58a0bwmrc5n8bzw1k59vlf7js82jr538iq73n4c9xlrm4kcx2q";
  };
  };
  racketThinBuildInputs = [ self."drracket-plugin-lib" self."gui-lib" self."string-constants-lib" self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "graphics" = self.lib.mkRacketDerivation rec {
  pname = "graphics";
  src = fetchgit {
    name = "graphics";
    url = "git://github.com/wargrey/graphics.git";
    rev = "50751297f244a01ac734099b9a1e9be97cd36f3f";
    sha256 = "0a1b52c5fnc4xa9kivzkzv1j71biv49zkvjcrvx12c5qdyly5j4i";
  };
  racketThinBuildInputs = [ self."graphics+w3s" self."base" self."digimon" self."math-lib" self."draw-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."digimon" ];
  circularBuildInputs = [ "graphics" "w3s" ];
  reverseCircularBuildInputs = [  ];
  };
  "graphics+w3s" = self.lib.mkRacketDerivation rec {
  pname = "graphics+w3s";

  extraSrcs = [ self."graphics".src self."w3s".src ];
  racketThinBuildInputs = [ self."base" self."digimon" self."digimon" self."draw-lib" self."math-lib" self."racket-doc" self."scribble-lib" self."typed-racket-doc" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [ "graphics" "w3s" ];
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
    rev = "91d71c6082fec4197aaf9ade57aceb148116c11c";
    sha256 = "0imkmgq0b4dsd4k674cc9y79g7lqrnn7f29kbwxh87vdvw7jh7pf";
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
    rev = "91d71c6082fec4197aaf9ade57aceb148116c11c";
    sha256 = "0imkmgq0b4dsd4k674cc9y79g7lqrnn7f29kbwxh87vdvw7jh7pf";
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
    rev = "91d71c6082fec4197aaf9ade57aceb148116c11c";
    sha256 = "0imkmgq0b4dsd4k674cc9y79g7lqrnn7f29kbwxh87vdvw7jh7pf";
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
    rev = "91d71c6082fec4197aaf9ade57aceb148116c11c";
    sha256 = "0imkmgq0b4dsd4k674cc9y79g7lqrnn7f29kbwxh87vdvw7jh7pf";
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
    rev = "57a015b2ed7d4a8425b3d61213567322de9d2573";
    sha256 = "0f5hwlwpykzw1pmvaakiq3ywrivn1aikihgp93v1qknc3i9sbpzz";
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
    rev = "8892d586fa19376ce060a3b62f3c472e09a56bba";
    sha256 = "0sngk5ls0snnaq5xfmjczf741yx75vh8z9frjg2xxn5kz5y2dd3f";
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
    rev = "39c36beb3329935b198c73a2010c37314686ab82";
    sha256 = "0viv4vdix3ixvswpc6nnfx4q4if9vlcajrghlcanfvxcrvr5p4zw";
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
    rev = "4411c3575f2f26269dc48fd9005b4ee7a898df26";
    sha256 = "0i40p3p4m5r36bcxlpq79q16cd5z4y5jh25kbg6dzagrlgr5n6i6";
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
    rev = "0e4d77fd435fb985159e021cb2a11e90398e0ce9";
    sha256 = "1zqcwqvb5dy9dh2acca63r4s6a2y8amlzsbq9w30y9bzqz6izhqs";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."scribble-abbrevs" self."scribble-lib" self."math-lib" self."pict-lib" self."plot-lib" self."reprovide-lang" self."gtp-util" self."rackunit-lib" self."racket-doc" self."scribble-doc" self."pict-lib" self."pict-doc" self."plot-doc" self."rackunit-abbrevs" self."typed-racket-doc" self."gtp-util" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gtp-util" = self.lib.mkRacketDerivation rec {
  pname = "gtp-util";
  src = fetchgit {
    name = "gtp-util";
    url = "git://github.com/bennn/gtp-util.git";
    rev = "e1c3d7b4ed1128271324201171240e111ce51419";
    sha256 = "0ala5g7cbwpl6pxrfhq7zgryvby2y755da9xix3wa2wr0426hzwc";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."pict-lib" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."scribble-doc" self."rackunit-abbrevs" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui" = self.lib.mkRacketDerivation rec {
  pname = "gui";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui.zip";
    sha1 = "4a5a3522454e2d77220bacbc1961d05bbd3ac11f";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."gui-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-aarch64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-aarch64-macosx";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/3efcb9bcca2ad3c24c3903229dbd6820559f0d08/gui-aarch64-macosx.zip";
    sha1 = "3efcb9bcca2ad3c24c3903229dbd6820559f0d08";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-doc" = self.lib.mkRacketDerivation rec {
  pname = "gui-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-doc.zip";
    sha1 = "32be7366cc027402821f329d884fcf06559c2459";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."at-exp-lib" self."draw-lib" self."scribble-lib" self."snip-lib" self."string-constants-lib" self."syntax-color-lib" self."wxme-lib" self."gui-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-i386-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-i386-macosx.zip";
    sha1 = "9f7027a88155f81881633b58d2bb25a9318dfcb7";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-lib.zip";
    sha1 = "25d16a5aa68890dee32487064db2c99b663b6b1c";
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
    rev = "e975632785a322f86a12f4c0faca73d075d4fb50";
    sha256 = "0my5xgcpnngmdnlc7wqzv3q53hw5m3f5ksqdfz9jg6wn17y6raaz";
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
    rev = "e975632785a322f86a12f4c0faca73d075d4fb50";
    sha256 = "0my5xgcpnngmdnlc7wqzv3q53hw5m3f5ksqdfz9jg6wn17y6raaz";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-pkg-manager-lib" = self.lib.mkRacketDerivation rec {
  pname = "gui-pkg-manager-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-pkg-manager-lib.zip";
    sha1 = "a20a06334fcde8b741686ca9fe6d061d3c53c872";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-ppc-macosx.zip";
    sha1 = "3b2e7f2eb63776fed89dbe071cda1d4b30ec80aa";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-test" = self.lib.mkRacketDerivation rec {
  pname = "gui-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-test.zip";
    sha1 = "ba76299125607db38def2e50ad232892b00f8cb6";
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
    rev = "fbc76d2dc8d82582cb16257ac7117f3b8e989344";
    sha256 = "0z2kmlz8msk4pfb5j520801bwpridmr0namq702hliwpc9zw9snr";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "gui-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-win32-i386.zip";
    sha1 = "c6ab4921ed72b4cc7e055abd6f39daf4c94a8115";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "gui-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-win32-x86_64.zip";
    sha1 = "ba6f8446971de8afe10e66d4993e2c480a8635b3";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "gui-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-x86_64-linux-natipkg.zip";
    sha1 = "26782cf3e86f95e6329a50281deb69ff8fb5b67d";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "gui-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "gui-x86_64-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/gui-x86_64-macosx.zip";
    sha1 = "23afd626d09c0518ccd532eb5187251eb3850a43";
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
    rev = "e90ace9e4a056ec0a2a267f220cb29b756cbefce";
    sha256 = "0yx35jarlcdwi956n3prnv4zj96b3zi73q8y07viqm384bp47jk0";
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
    rev = "e90ace9e4a056ec0a2a267f220cb29b756cbefce";
    sha256 = "0yx35jarlcdwi956n3prnv4zj96b3zi73q8y07viqm384bp47jk0";
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
    rev = "e90ace9e4a056ec0a2a267f220cb29b756cbefce";
    sha256 = "0yx35jarlcdwi956n3prnv4zj96b3zi73q8y07viqm384bp47jk0";
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
    rev = "e90ace9e4a056ec0a2a267f220cb29b756cbefce";
    sha256 = "0yx35jarlcdwi956n3prnv4zj96b3zi73q8y07viqm384bp47jk0";
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
    rev = "e90ace9e4a056ec0a2a267f220cb29b756cbefce";
    sha256 = "0yx35jarlcdwi956n3prnv4zj96b3zi73q8y07viqm384bp47jk0";
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
    rev = "a01b9cce0c2397d3e1049d4e6932b48b51e65b13";
    sha256 = "0jp1f1ha4ckmf770dp18imv96k9xzsibf3f1mac55p4c55p3hvar";
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
    rev = "a48a10112e78f74e51a879ec9faf38e268a97697";
    sha256 = "0p1nr8gnskk8pwg14m5jb6s4yvldkda6a1z6i8ygl0xdf6pn3833";
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
  "hash-view" = self.lib.mkRacketDerivation rec {
  pname = "hash-view";
  src = self.lib.extractPath {
    path = "hash-view";
    src = fetchgit {
    name = "hash-view";
    url = "git://github.com/rmculpepper/racket-hash-view.git";
    rev = "7bfad3b89241beaca45f43ec1d70ef3ed268b495";
    sha256 = "0xsnszw3kxwsm48nw33762mrhpilh4vj7vn7zf7ws6ygmfh6k4k1";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."hash-view-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "hash-view-lib" = self.lib.mkRacketDerivation rec {
  pname = "hash-view-lib";
  src = self.lib.extractPath {
    path = "hash-view-lib";
    src = fetchgit {
    name = "hash-view-lib";
    url = "git://github.com/rmculpepper/racket-hash-view.git";
    rev = "7bfad3b89241beaca45f43ec1d70ef3ed268b495";
    sha256 = "0xsnszw3kxwsm48nw33762mrhpilh4vj7vn7zf7ws6ygmfh6k4k1";
  };
  };
  racketThinBuildInputs = [ self."base" ];
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
    rev = "cd03acd15d439869dfb902ddc25712e324e4c499";
    sha256 = "1pmlcnp64bm8pq4n322k2wprzxmihrsxm43ycv6wanmgvny8plxw";
  };
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."plot-lib" self."profile-lib" self."rackunit-lib" self."web-server-lib" self."egg-herbie-windows" self."egg-herbie-osx" self."egg-herbie-linux" self."regraph" self."rival" self."fpbench" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/htdp.zip";
    sha1 = "6c5094567b860ff3b09d5dc21f719eb4a2a04bf5";
  };
  racketThinBuildInputs = [ self."htdp-lib" self."htdp-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-doc" = self.lib.mkRacketDerivation rec {
  pname = "htdp-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/htdp-doc.zip";
    sha1 = "870d7c5f47585001ef21ae686e14a886f77a2efa";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/htdp-lib.zip";
    sha1 = "26ef2eb5ef7a380abdbe196078320f08453e5c1f";
  };
  racketThinBuildInputs = [ self."deinprogramm-signature+htdp-lib" self."base" self."compatibility-lib" self."draw-lib" self."drracket-plugin-lib" self."errortrace-lib" self."html-lib" self."images-gui-lib" self."images-lib" self."net-lib" self."pconvert-lib" self."plai-lib" self."r5rs-lib" self."sandbox-lib" self."scheme-lib" self."scribble-lib" self."slideshow-lib" self."snip-lib" self."srfi-lite-lib" self."string-constants-lib" self."typed-racket-lib" self."typed-racket-more" self."web-server-lib" self."wxme-lib" self."gui-lib" self."pict-lib" self."racket-index" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "htdp-lib" "deinprogramm-signature" ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-test" = self.lib.mkRacketDerivation rec {
  pname = "htdp-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/htdp-test.zip";
    sha1 = "7349206d92da821ceb1ac4280d03698dc1de5759";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."scheme-lib" self."srfi-lite-lib" self."compatibility-lib" self."gui-lib" self."racket-test" self."rackunit-lib" self."profile-lib" self."wxme-lib" self."pconvert-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "htdp-trace" = self.lib.mkRacketDerivation rec {
  pname = "htdp-trace";
  src = self.lib.extractPath {
    path = "htdp-trace";
    src = fetchgit {
    name = "htdp-trace";
    url = "git://github.com/djh-uwaterloo/uwaterloo-racket.git";
    rev = "24f1c0034ea24180c4d501eb51efd96f5f349215";
    sha256 = "0s58a0bwmrc5n8bzw1k59vlf7js82jr538iq73n4c9xlrm4kcx2q";
  };
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html" = self.lib.mkRacketDerivation rec {
  pname = "html";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/html.zip";
    sha1 = "551031cfc9d2271d2d464769bc039593d02e82d6";
  };
  racketThinBuildInputs = [ self."html-lib" self."html-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-doc" = self.lib.mkRacketDerivation rec {
  pname = "html-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/html-doc.zip";
    sha1 = "ba2b0357eacc712e59269e3d33bbad8ac0050f51";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."html-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-examples" = self.lib.mkRacketDerivation rec {
  pname = "html-examples";
  src = fetchgit {
    name = "html-examples";
    url = "git://github.com/pmatos/html-examples.git";
    rev = "d2982629acdfb103d0b7f82bc337ee1d973a9efb";
    sha256 = "026vx35xahggf9xp30l64abc533hx0zcccyhf9ngzifwhkf8vsn1";
  };
  racketThinBuildInputs = [ self."txexpr" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "html-lib" = self.lib.mkRacketDerivation rec {
  pname = "html-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/html-lib.zip";
    sha1 = "3d24695c11c67b9e879bd53bd70a40eb10066fc3";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/html-test.zip";
    sha1 = "d6fed7fa57092a424b4d7518cf564d6119e089df";
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
    rev = "bf006350fbbbf6f0d3297200fd607ecd2a2ddef1";
    sha256 = "1p4iy7s000w1h91k7na565yssqs5g47f9ry851c42naxgs4whj5h";
  };
  racketThinBuildInputs = [ self."base" self."html-lib" self."rackunit-lib" self."net-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http-client" = self.lib.mkRacketDerivation rec {
  pname = "http-client";
  src = fetchgit {
    name = "http-client";
    url = "git://github.com/yanyingwang/http-client.git";
    rev = "2d1a1dd2187f3e36b7558524d9260c42f06f7130";
    sha256 = "1ajasgvqy8da056dqxis9962zclidgjaps0qs56h6avm82bnbcsm";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."at-exp-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http-easy" = self.lib.mkRacketDerivation rec {
  pname = "http-easy";
  src = self.lib.extractPath {
    path = "http-easy";
    src = fetchgit {
    name = "http-easy";
    url = "git://github.com/Bogdanp/racket-http-easy.git";
    rev = "4b05e13f795e3aa918a52547e1d64267b1118e31";
    sha256 = "1q0nrmrwhyjf164nvbgi4pi9nk320y7h9b1fn0rcw82zcdph2y76";
  };
  };
  racketThinBuildInputs = [ self."base" self."memoize" self."net-cookies-lib" self."resource-pool-lib" self."net-cookies-doc" self."net-doc" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "http-easy-test" = self.lib.mkRacketDerivation rec {
  pname = "http-easy-test";
  src = self.lib.extractPath {
    path = "http-easy-test";
    src = fetchgit {
    name = "http-easy-test";
    url = "git://github.com/Bogdanp/racket-http-easy.git";
    rev = "4b05e13f795e3aa918a52547e1d64267b1118e31";
    sha256 = "1q0nrmrwhyjf164nvbgi4pi9nk320y7h9b1fn0rcw82zcdph2y76";
  };
  };
  racketThinBuildInputs = [ self."base" self."http-easy" self."net-cookies-lib" self."rackunit-lib" self."web-server-lib" ];
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
    rev = "aafdea48a4f1e6f8579531350aee3691f4060129";
    sha256 = "1pjalacr3i7hqzqyc8riixq1lwcj61chk8g4glmpfw12qkpkp1dh";
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
    rev = "24fd9ca7ca9b96e3072d37306dc79edf24ba4ef1";
    sha256 = "00ymf3mcwzr482q0mlc5syj86767afhf2b5sqiqs9m5ikw0hkcnb";
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
    rev = "2466b95c8df3b5117277c7a0e33e3b7f2f170cf0";
    sha256 = "0rhw001c98kqg1pmnxaynzh99n8fp8rxca0lncp520flf0s32mwp";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/icons.zip";
    sha1 = "4911d4be86dd8703ce9a9d3cbcfb94898671b619";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/images.zip";
    sha1 = "526450069db886dfeea2582ed5291a20d027c6ea";
  };
  racketThinBuildInputs = [ self."images-lib" self."images-gui-lib" self."images-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-doc" = self.lib.mkRacketDerivation rec {
  pname = "images-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/images-doc.zip";
    sha1 = "e5f4fd39eee2dd21faedb7c6e975f055a397045b";
  };
  racketThinBuildInputs = [ self."base" self."images-lib" self."draw-doc" self."gui-doc" self."pict-doc" self."slideshow-doc" self."typed-racket-doc" self."draw-lib" self."gui-lib" self."pict-lib" self."racket-doc" self."scribble-lib" self."slideshow-lib" self."typed-racket-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "images-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/images-gui-lib.zip";
    sha1 = "2c3e7b4eb613f46dcc1d4bbdda14013feb425afb";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-lib" = self.lib.mkRacketDerivation rec {
  pname = "images-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/images-lib.zip";
    sha1 = "2008bb5b8a5533d5e13ca7543ff5cc31cac650bd";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."typed-racket-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "images-test" = self.lib.mkRacketDerivation rec {
  pname = "images-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/images-test.zip";
    sha1 = "5984ce1d7d9f56c48b57137a1289f05e998c7e38";
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
    rev = "126e872caa2190e7f37663161a0853575aa92ad8";
    sha256 = "1j4bv26464l6r57mpcdrrybpav4lzdp3ljhyd57zlarjx44ayrw5";
  };
  racketThinBuildInputs = [ self."base" self."binaryio" self."gregor-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "interactive-syntax" = self.lib.mkRacketDerivation rec {
  pname = "interactive-syntax";
  src = fetchgit {
    name = "interactive-syntax";
    url = "git://github.com/videolang/interactive-syntax.git";
    rev = "8c13d83ac0f5dbd624d59083b32f765952d1d440";
    sha256 = "0120p5dyxk6595m1j0k64i781d0pyq9yhzlyg2fmv4dfsfzimh6h";
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
    rev = "bcd0c4229a05491923550b50c003d432be982028";
    sha256 = "0chx1mgmfw8ssrqilfwvjsqk322cryfwfkv534rbvfp8mp8njhpw";
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
    rev = "bcd0c4229a05491923550b50c003d432be982028";
    sha256 = "0chx1mgmfw8ssrqilfwvjsqk322cryfwfkv534rbvfp8mp8njhpw";
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
    rev = "bcd0c4229a05491923550b50c003d432be982028";
    sha256 = "0chx1mgmfw8ssrqilfwvjsqk322cryfwfkv534rbvfp8mp8njhpw";
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
    rev = "bcd0c4229a05491923550b50c003d432be982028";
    sha256 = "0chx1mgmfw8ssrqilfwvjsqk322cryfwfkv534rbvfp8mp8njhpw";
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
    rev = "4a988f6537fb738b4fe842c404f9d78f658ab76f";
    sha256 = "1v56pf4r6d7ap2wq8hmb7brc972hbl6s7s2swc20gy7bhqbgvfks";
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
    rev = "9af0e87d61565a9ecb41119c481e7e36c0c5287d";
    sha256 = "0z1gaa1135bk8k7m2hc6lgsi3p79zzf2mc4fhw5b185s1m92vb3a";
  };
  racketThinBuildInputs = [ self."base" self."zeromq-r-lib" self."sandbox-lib" self."uuid" self."sha" self."racket-doc" self."scribble-lib" self."scribble-doc" ];
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
    rev = "73e97e426eff151ffd705059771c5c92f2da4697";
    sha256 = "0nhv54bsyg2qpkwh71xwc8r6q47dv12q09qnqfyn2vh5pd949g9d";
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
    rev = "f96d3f212519f4ff2aef828e7b891971b82babb8";
    sha256 = "10q0bb8x5206q8sb6lslsgm7q04z5rg39p80j163m172c7c06rcs";
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
  "keyring" = self.lib.mkRacketDerivation rec {
  pname = "keyring";
  src = self.lib.extractPath {
    path = "keyring";
    src = fetchgit {
    name = "keyring";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."keyring-lib" self."keyring-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "keyring-doc" = self.lib.mkRacketDerivation rec {
  pname = "keyring-doc";
  src = self.lib.extractPath {
    path = "keyring-doc";
    src = fetchgit {
    name = "keyring-doc";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."keyring-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "keyring-get-pass-lib" = self.lib.mkRacketDerivation rec {
  pname = "keyring-get-pass-lib";
  src = self.lib.extractPath {
    path = "keyring-get-pass-lib";
    src = fetchgit {
    name = "keyring-get-pass-lib";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."get-pass" self."keyring-lib" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "keyring-keychain-lib" = self.lib.mkRacketDerivation rec {
  pname = "keyring-keychain-lib";
  src = self.lib.extractPath {
    path = "keyring-keychain-lib";
    src = fetchgit {
    name = "keyring-keychain-lib";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."keyring-lib" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "keyring-lib" = self.lib.mkRacketDerivation rec {
  pname = "keyring-lib";
  src = self.lib.extractPath {
    path = "keyring-lib";
    src = fetchgit {
    name = "keyring-lib";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "keyring-secret-service-lib" = self.lib.mkRacketDerivation rec {
  pname = "keyring-secret-service-lib";
  src = self.lib.extractPath {
    path = "keyring-secret-service-lib";
    src = fetchgit {
    name = "keyring-secret-service-lib";
    url = "git://github.com/samdphillips/racket-keyring.git";
    rev = "e90d649fea6533e903efe1961617e172a133b688";
    sha256 = "0rigp1ji95mn2kqxx7yyfcjs46pxrvv55jgbc45mqwa5kca80dsf";
  };
  };
  racketThinBuildInputs = [ self."base" self."dbus" self."keyring-lib" self."base" self."rackunit-lib" ];
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
  "kittle-buffer" = self.lib.mkRacketDerivation rec {
  pname = "kittle-buffer";
  src = fetchgit {
    name = "kittle-buffer";
    url = "git://github.com/KDr2/kittle-buffer.git";
    rev = "f80d8053880b38e95a484b1624223fd7cbec4bf7";
    sha256 = "11mr487snibryrirl11sy8v598wa762lz957blq9y5dsci2ji69n";
  };
  racketThinBuildInputs = [ self."base" self."gui" self."draw" self."srfi" ];
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
    rev = "93f3fd06ee596a62bb0b286cb6290a800e911154";
    sha256 = "0fdmvwd4snspqm5cxl30pd376q3d98fjngmr2a2qlxsgg27q6v55";
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
    rev = "93f3fd06ee596a62bb0b286cb6290a800e911154";
    sha256 = "0fdmvwd4snspqm5cxl30pd376q3d98fjngmr2a2qlxsgg27q6v55";
  };
  };
  racketThinBuildInputs = [ self."base" self."component-doc" self."component-lib" self."db-lib" self."gregor-lib" self."koyo-lib" self."libargon2" self."sandbox-lib" self."scribble-lib" self."srfi-lite-lib" self."web-server-lib" self."db-doc" self."gregor-doc" self."net-doc" self."racket-doc" self."srfi-doc-nonfree" self."web-server-doc" ];
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
    rev = "93f3fd06ee596a62bb0b286cb6290a800e911154";
    sha256 = "0fdmvwd4snspqm5cxl30pd376q3d98fjngmr2a2qlxsgg27q6v55";
  };
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."component-lib" self."crypto-lib" self."db-lib" self."errortrace-lib" self."gregor-lib" self."html-lib" self."net-lib" self."readline-lib" self."srfi-lite-lib" self."unix-socket-lib" self."web-server-lib" self."at-exp-lib" ];
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
  "koyo-sessions-redis" = self.lib.mkRacketDerivation rec {
  pname = "koyo-sessions-redis";
  src = fetchgit {
    name = "koyo-sessions-redis";
    url = "git://github.com/Bogdanp/koyo-sessions-redis.git";
    rev = "e556fafb2f207eb4c74b66c8d1ae2f51d4b208b1";
    sha256 = "167dzz11yxx1knj4xgljj467c7pi5xrd283h8cs41y531miqf0qh";
  };
  racketThinBuildInputs = [ self."base" self."koyo-lib" self."redis-lib" self."koyo-doc" self."racket-doc" self."redis-doc" self."rackunit-lib" self."scribble-lib" ];
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
    rev = "93f3fd06ee596a62bb0b286cb6290a800e911154";
    sha256 = "0fdmvwd4snspqm5cxl30pd376q3d98fjngmr2a2qlxsgg27q6v55";
  };
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."component-lib" self."db-lib" self."gregor-lib" self."koyo-lib" self."libargon2" self."rackunit-lib" self."srfi-lite-lib" self."web-server-lib" ];
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
    rev = "91095643063329146e7d901b864e1438963bbc10";
    sha256 = "02q5apvc268v1dsd5nkafa411qhr595rrhj3d8hgrb6msh0cz0yi";
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
    rev = "9111401749ef9be7f162eec79961b448024522af";
    sha256 = "1rsqfwbdhd6xk585vwb2rpyv65jh868jrs43d355ady189lfh1jm";
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
    rev = "99b2131e08db61d8690c32d93dd6b31391649474";
    sha256 = "1v7yb8d10dkry3mkp83wb8vf0nyvhk8z9xs5l0xdrgy2a1kip74y";
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
    rev = "847bd5f42903fa1b357125cee67b9a2addf240c6";
    sha256 = "0n3f68z7rxa1rr2d8n4ypbrpz1vv2cwk3i3890fa4dn0h5pjjsa0";
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
    rev = "0a91d936fddf3c356c35782384ec83ceaa29bf0d";
    sha256 = "09cnsghlr5zn35h8zjfjl7ws9jlba9ahgcki94hy1jq7iasavczg";
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
    rev = "0a91d936fddf3c356c35782384ec83ceaa29bf0d";
    sha256 = "09cnsghlr5zn35h8zjfjl7ws9jlba9ahgcki94hy1jq7iasavczg";
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
    rev = "0a91d936fddf3c356c35782384ec83ceaa29bf0d";
    sha256 = "09cnsghlr5zn35h8zjfjl7ws9jlba9ahgcki94hy1jq7iasavczg";
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
    rev = "0a91d936fddf3c356c35782384ec83ceaa29bf0d";
    sha256 = "09cnsghlr5zn35h8zjfjl7ws9jlba9ahgcki94hy1jq7iasavczg";
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
    rev = "422f0c5f5c5bc58d950d54886f26eb27d56d3061";
    sha256 = "1jvmbw3xhnkl33y6js8ckn38cfjkzqkyfwx5di1fd3yiypyhxqw5";
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
    rev = "422f0c5f5c5bc58d950d54886f26eb27d56d3061";
    sha256 = "1jvmbw3xhnkl33y6js8ckn38cfjkzqkyfwx5di1fd3yiypyhxqw5";
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
    rev = "422f0c5f5c5bc58d950d54886f26eb27d56d3061";
    sha256 = "1jvmbw3xhnkl33y6js8ckn38cfjkzqkyfwx5di1fd3yiypyhxqw5";
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
    rev = "422f0c5f5c5bc58d950d54886f26eb27d56d3061";
    sha256 = "1jvmbw3xhnkl33y6js8ckn38cfjkzqkyfwx5di1fd3yiypyhxqw5";
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
    rev = "f7f46835ae5403d04947df062145dd98963789a1";
    sha256 = "0sdll593lxiqq2cjll1p4w0j3d799h2p6r1qyqwq4kxq99rgxm1v";
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
    rev = "f7f46835ae5403d04947df062145dd98963789a1";
    sha256 = "0sdll593lxiqq2cjll1p4w0j3d799h2p6r1qyqwq4kxq99rgxm1v";
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
    rev = "f7f46835ae5403d04947df062145dd98963789a1";
    sha256 = "0sdll593lxiqq2cjll1p4w0j3d799h2p6r1qyqwq4kxq99rgxm1v";
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
    rev = "f7f46835ae5403d04947df062145dd98963789a1";
    sha256 = "0sdll593lxiqq2cjll1p4w0j3d799h2p6r1qyqwq4kxq99rgxm1v";
  };
  };
  racketThinBuildInputs = [ self."base" self."lathe-ordinals-lib" self."parendown-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "layout" = self.lib.mkRacketDerivation rec {
  pname = "layout";
  src = fetchgit {
    name = "layout";
    url = "git://github.com/SimonLSchlee/layout.git";
    rev = "5f7f0832057ea201a3d913ed943b60aaaef452e7";
    sha256 = "0phh1b8cba14syqq1j39bl70iapp8g8c0aprfs2ijj4kfqpphm12";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."pict-lib" self."reprovide-lang-lib" self."rackunit-chk" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "layout-interactive" = self.lib.mkRacketDerivation rec {
  pname = "layout-interactive";
  src = fetchgit {
    name = "layout-interactive";
    url = "git://github.com/SimonLSchlee/layout-interactive.git";
    rev = "bf245c3ecbc2c93cc236fd27ea7b37bb8560eccd";
    sha256 = "0b1251h1csz7zx87vqhf4sgwq7gx65jaj50wdg6das2xzn52z4k9";
  };
  racketThinBuildInputs = [ self."base" self."layout" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lazy" = self.lib.mkRacketDerivation rec {
  pname = "lazy";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/lazy.zip";
    sha1 = "0f4d20d5661f162eaf448e52728662cb7186a381";
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
    rev = "468ec6a1a79284ca6f38371678e710e124285241";
    sha256 = "00ng8qfsalf59rhvcqk9gc228a74fzzl7p1nl22cymjn09pa71y5";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."relation" self."social-contract" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."collections-doc" self."functional-doc" self."rackunit-lib" self."pict-lib" self."cover" self."cover-coveralls" self."sandbox-lib" ];
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
    url = "https://racket.defn.io/libsqlite3-x86_64-linux-3.32.0.tar.gz";
    sha1 = "274aa42cb70bc1300e237d7a0b261fbb6def986e";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "libsqlite3-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "libsqlite3-x86_64-macosx";
  src = fetchurl {
    url = "https://racket.defn.io/libsqlite3-x86_64-macosx-3.32.0.tar.gz";
    sha1 = "aa33b198e392c8da05ac3ebbacff7f9b6fee2bf8";
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
    rev = "2ef7b4535d8ae1eb7cc2e16e2b630c30a4b9a34d";
    sha256 = "0v9bzkbx8if209lk895g6l04wnw7dk0kmivz2m63jszg288rsx0a";
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
    rev = "c40c5adfedf632bc1fdbad3e0e2763b134ee3ff5";
    sha256 = "1jcdlidbp1nq3jh99wsghzmyamfcs5zwljarrwcyfnkmkaxvviqg";
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
  "linux-shared-libraries" = self.lib.mkRacketDerivation rec {
  pname = "linux-shared-libraries";
  src = fetchgit {
    name = "linux-shared-libraries";
    url = "git://github.com/soegaard/linux-shared-libraries.git";
    rev = "f49d1bd6794437482c46d351c71313070e0244d5";
    sha256 = "0acxr2kq19k0f4piniahww1a6fwbap7zdsldnl9fzsdf2mm50n68";
  };
  racketThinBuildInputs = [ self."base" ];
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
  "list-plus" = self.lib.mkRacketDerivation rec {
  pname = "list-plus";
  src = fetchgit {
    name = "list-plus";
    url = "git://github.com/sorawee/list-plus.git";
    rev = "ca3957db266315a0398ad5dff957c58d4f2e8c8f";
    sha256 = "0i579gwvnq75v8s3qa35wncm0p5hy4bps381xhmqf08rhqsnw0lh";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "cde478d1ab11c52f7f23763174ae9ae16402a918";
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
    rev = "ce063c7e45d5abb7c187766b3ab7045ef2f84099";
    sha256 = "0np983g604bamxrbcdqhlvk46kbhc6q33dw13s3wrqwa2i8j2x7m";
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
    rev = "c7098540edfbaa7ea8cee3f867ca72391f0f9432";
    sha256 = "1q8xgblfdvilsgz62xsxvyr9a2czzsgp98kqbm5wpajczh7s6bzm";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "lti-freq-domain-toolbox" = self.lib.mkRacketDerivation rec {
  pname = "lti-freq-domain-toolbox";
  src = fetchgit {
    name = "lti-freq-domain-toolbox";
    url = "git://github.com/istefanis/lti-freq-domain-toolbox.git";
    rev = "1465a3458840a2e0ac58ec2a482e27abf99cb911";
    sha256 = "05z5aszr7hz5xnxdb6b9msinyihhw2dgjxr1l32iqd543xh4gb3a";
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
    rev = "1f66e2155f947fe6d909eff394052be7d2b57ad1";
    sha256 = "0vpaq1dhb7x4s24zqlzksz9g50lsrr5rfyvwprlnwrjsxhw0309z";
  };
  racketThinBuildInputs = [ self."base" self."functional-lib" ];
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
    rev = "8c0a6e11f14af23dcbd72890a51d4fd77350a3d7";
    sha256 = "0k3z9b4x3hhipkg871j3ycyb6l63cbw40zflbmv5n801nxabqys3";
  };
  racketThinBuildInputs = [ self."2d-lib" self."base" self."data-lib" self."drracket-plugin-lib" self."drracket-tool-lib" self."gui-lib" self."parser-tools-lib" self."pict-lib" self."rackunit-lib" self."scribble-lib" self."syntax-color-lib" self."draw-lib" self."ppict" self."slideshow-lib" self."unstable-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "macro-debugger" = self.lib.mkRacketDerivation rec {
  pname = "macro-debugger";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/macro-debugger.zip";
    sha1 = "e9d1a07ba6933de82f1994bb075626b3e61cad03";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."class-iop-lib" self."compatibility-lib" self."data-lib" self."gui-lib" self."images-lib" self."images-gui-lib" self."parser-tools-lib" self."macro-debugger-text-lib" self."snip-lib" self."draw-lib" self."racket-index" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "macro-debugger-text-lib" = self.lib.mkRacketDerivation rec {
  pname = "macro-debugger-text-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/macro-debugger-text-lib.zip";
    sha1 = "ef611ad2211ceb60fb1611446856f0731a01d1a6";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/main-distribution.zip";
    sha1 = "d0d3931201f2b8961b2b17c0a8758f162bec17f6";
  };
  racketThinBuildInputs = [ self."2d" self."algol60" self."at-exp-lib" self."compatibility" self."contract-profile" self."compiler" self."data" self."datalog" self."db" self."deinprogramm" self."draw" self."draw-doc" self."draw-lib" self."drracket" self."drracket-tool" self."eopl" self."errortrace" self."future-visualizer" self."future-visualizer-typed" self."frtime" self."games" self."gui" self."htdp" self."html" self."icons" self."images" self."lazy" self."macro-debugger" self."macro-debugger-text-lib" self."make" self."math" self."mysterx" self."mzcom" self."mzscheme" self."net" self."net-cookies" self."optimization-coach" self."option-contract" self."parser-tools" self."pconvert-lib" self."pict" self."pict-snip" self."picturing-programs" self."plai" self."planet" self."plot" self."preprocessor" self."profile" self."r5rs" self."r6rs" self."racket-doc" self."distributed-places" self."racket-cheat" self."racket-index" self."racket-lib" self."racklog" self."rackunit" self."rackunit-typed" self."readline" self."realm" self."redex" self."sandbox-lib" self."sasl" self."schemeunit" self."scribble" self."serialize-cstruct-lib" self."sgl" self."shell-completion" self."slatex" self."slideshow" self."snip" self."srfi" self."string-constants" self."swindle" self."syntax-color" self."trace" self."typed-racket" self."typed-racket-more" self."unix-socket" self."web-server" self."wxme" self."xrepl" self."ds-store" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "main-distribution-test" = self.lib.mkRacketDerivation rec {
  pname = "main-distribution-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/main-distribution-test.zip";
    sha1 = "c07b83132e1bb63b473400584bf5405c9e8d69be";
  };
  racketThinBuildInputs = [ self."racket-test" self."racket-test-extra" self."rackunit-test" self."draw-test" self."gui-test" self."db-test" self."htdp-test" self."html-test" self."redex-test" self."drracket-test" self."profile-test" self."srfi-test" self."errortrace-test" self."r6rs-test" self."web-server-test" self."typed-racket-test" self."xrepl-test" self."scribble-test" self."compiler-test" self."compatibility-test" self."data-test" self."net-test" self."net-cookies-test" self."pconvert-test" self."planet-test" self."syntax-color-test" self."images-test" self."plot-test" self."pict-test" self."pict-snip-test" self."math-test" self."racket-benchmarks" self."drracket-tool-test" self."2d-test" self."option-contract-test" self."sasl-test" self."wxme-test" self."unix-socket-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "majordomo" = self.lib.mkRacketDerivation rec {
  pname = "majordomo";
  src = fetchgit {
    name = "majordomo";
    url = "git://github.com/dstorrs/majordomo.git";
    rev = "b8826dee4233aa314c3a19fed0164b8bc446a115";
    sha256 = "020k433agslb149rnzmsr6k15ps8h8fm8qnny3w57iisic0vj3ql";
  };
  racketThinBuildInputs = [ self."base" self."struct-plus-plus" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "make" = self.lib.mkRacketDerivation rec {
  pname = "make";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/make.zip";
    sha1 = "f7e29fbb372b6759cdd69b8ba011b000dfb8a145";
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
    rev = "43e0d6bb4953e9e880aa6d5b81b9fcf49db9114f";
    sha256 = "1p4yas9lrmjz808dja1b3ci4mq18c6nymdr7g8cbnyms05a5jn4s";
  };
  racketThinBuildInputs = [ self."draw-lib" self."errortrace-lib" self."gui-lib" self."db-lib" self."math-lib" self."base" self."geoid" self."rackunit-lib" self."scribble-lib" self."draw-doc" self."gui-doc" self."racket-doc" self."al2-test-runner" ];
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
    rev = "94cef98a6631a017d84324063af0a3be7cce0b38";
    sha256 = "1j7p1hi5lg8s9iyq2cylhbamjn3vgk0ki3xz3fchz5xxbmkwz8hc";
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
    rev = "94cef98a6631a017d84324063af0a3be7cce0b38";
    sha256 = "1j7p1hi5lg8s9iyq2cylhbamjn3vgk0ki3xz3fchz5xxbmkwz8hc";
  };
  };
  racketThinBuildInputs = [ self."base" self."marionette-lib" self."sandbox-lib" self."scribble-lib" self."net-doc" self."racket-doc" ];
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
    rev = "94cef98a6631a017d84324063af0a3be7cce0b38";
    sha256 = "1j7p1hi5lg8s9iyq2cylhbamjn3vgk0ki3xz3fchz5xxbmkwz8hc";
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
    rev = "94cef98a6631a017d84324063af0a3be7cce0b38";
    sha256 = "1j7p1hi5lg8s9iyq2cylhbamjn3vgk0ki3xz3fchz5xxbmkwz8hc";
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
    rev = "fc03a2728b12006b21c90b6c480cfe6ae91a4cbe";
    sha256 = "11sikv7vgg4q7lj3j9g6bqvn06bi92w09r25677wy8znzcxnmaz8";
  };
  racketThinBuildInputs = [ self."base" self."parsack" self."sandbox-lib" self."scribble-lib" self."srfi-lite-lib" self."threading-lib" self."at-exp-lib" self."html-lib" self."racket-doc" self."rackunit-lib" self."redex-lib" self."scribble-doc" self."sexp-diff-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "markdown-ng" = self.lib.mkRacketDerivation rec {
  pname = "markdown-ng";
  src = fetchgit {
    name = "markdown-ng";
    url = "git://github.com/pmatos/markdown-ng.git";
    rev = "ef5eb23b8fd554d7230678dfade0541c6c06ae85";
    sha256 = "1q1an7h2mclzg1midaxfsvyslvfqz2n0pfzj9p78if7wy2s9is9l";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math.zip";
    sha1 = "fbdc8f722d519d97a77e309e6f29d62e3938b6e4";
  };
  racketThinBuildInputs = [ self."math-lib" self."math-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-aarch64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-aarch64-macosx";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/88e1e2ec3c4cb0de1ab41c6169027fb8aee34951/math-aarch64-macosx.zip";
    sha1 = "88e1e2ec3c4cb0de1ab41c6169027fb8aee34951";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-doc" = self.lib.mkRacketDerivation rec {
  pname = "math-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-doc.zip";
    sha1 = "8066de0f0871e1a8ad55413be9e9cab1e8c64267";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."at-exp-lib" self."math-lib" self."plot-gui-lib" self."sandbox-lib" self."scribble-lib" self."typed-racket-lib" self."2d-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "math-i386-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-i386-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-i386-macosx.zip";
    sha1 = "43418819d4df0fcdb81e665585334d662000866c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-lib" = self.lib.mkRacketDerivation rec {
  pname = "math-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-lib.zip";
    sha1 = "a4d1249575cedc84c3002fd744050abf231508f4";
  };
  racketThinBuildInputs = [ self."base" self."r6rs-lib" self."typed-racket-lib" self."typed-racket-more" self."math-i386-macosx" self."math-x86_64-macosx" self."math-ppc-macosx" self."math-win32-i386" self."math-win32-x86_64" self."math-x86_64-linux-natipkg" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-ppc-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-ppc-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-ppc-macosx.zip";
    sha1 = "7175876575dcf8e3e59e45e639dd2efea21a563c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-test" = self.lib.mkRacketDerivation rec {
  pname = "math-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-test.zip";
    sha1 = "6ae87363b39272b4c8ce078ab8fea1ebc7b42226";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."racket-test" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-win32-i386" = self.lib.mkRacketDerivation rec {
  pname = "math-win32-i386";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-win32-i386.zip";
    sha1 = "24890cca9399c2ae118e4381a75fd48f4a9ee83f";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-win32-x86_64" = self.lib.mkRacketDerivation rec {
  pname = "math-win32-x86_64";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-win32-x86_64.zip";
    sha1 = "8ebb93b03e975c75bfe2fb6aa73b0df3ce70a6ee";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-x86_64-linux-natipkg" = self.lib.mkRacketDerivation rec {
  pname = "math-x86_64-linux-natipkg";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-x86_64-linux-natipkg.zip";
    sha1 = "54e772497f9b99032afec4b26ddd9fb2b00ec375";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "math-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "math-x86_64-macosx";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/math-x86_64-macosx.zip";
    sha1 = "123305dc3f19c54bb8b32405bee2f695f34b3b76";
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
    rev = "fc6c78f79ac89cf488a5ccc5fc20391bd254886c";
    sha256 = "1kxnq5mda0mgjbixqnbq1h9fs1f93kaswh3paa8iq4xna8fv4krr";
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
    rev = "47ae265f73cbb92ff3e7bdd61e49f4af17597fdf";
    sha256 = "1ihzwhdk4fh1rcnbw2g50nbk6viy6bf2zan1gb20papr376yfdcd";
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
  "mind-map" = self.lib.mkRacketDerivation rec {
  pname = "mind-map";
  src = fetchgit {
    name = "mind-map";
    url = "git://github.com/zyrolasting/mind-map.git";
    rev = "8401400f1dbc7956357cd27563b6926f4e429d7c";
    sha256 = "0gcsq8yna3n50c4zazdw17wv25yx9da6wl75w9pgrs54zhi95dpb";
  };
  racketThinBuildInputs = [ self."base" self."racket-graphviz" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
  "mini-theme" = self.lib.mkRacketDerivation rec {
  pname = "mini-theme";
  src = fetchgit {
    name = "mini-theme";
    url = "git://github.com/dannypsnl/mini-theme.git";
    rev = "4d5d94cccd987fa1d4ac3ae98e2f01b7cefa46ed";
    sha256 = "14bcy4ai1k8c2ffhbdavfj0zd6q93kdnyjf8qrf25ssjck0f37xf";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" ];
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
    rev = "597861a4c237fc22177ae0db230bdf89dc86873f";
    sha256 = "0xmx5cg8yypr7fm8ppspjxf8wkp4484485ddkhi1m8iys9b7nlm7";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."faster-minikanren" self."ee-lib" ];
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
  "mixfix" = self.lib.mkRacketDerivation rec {
  pname = "mixfix";
  src = fetchgit {
    name = "mixfix";
    url = "git://github.com/sorawee/mixfix.git";
    rev = "db91d60448adbce889d3c85dd7553274f8db971a";
    sha256 = "1w2rhlww8msz2ga9gwnjb7m3vx5iabb591fm5as1jb2sfvqacgci";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "8ead18bc73fa629ae352471c63a7b0847b18fb3f";
    sha256 = "08q1pcl7fz5c5d18iniqrr103w7g5dvbsf8qx4s0w6mzhk8nja54";
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
    rev = "5e8e2a1dd125e5e437510c87dabf903d0ec25749";
    sha256 = "0mwn2mf15sbhcng65n5334dasgl95x9i2wnrzw79h0pnip1yjz1i";
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
    rev = "5e8e2a1dd125e5e437510c87dabf903d0ec25749";
    sha256 = "0mwn2mf15sbhcng65n5334dasgl95x9i2wnrzw79h0pnip1yjz1i";
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
    rev = "4d2271f47d3c40e121afec4afc37de8adb4cf773";
    sha256 = "03c5ivizrrwj6rc4vqzkafy57svrk1d3g4dfxz3qllgdbd1cwqfw";
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
    rev = "10cf376f07755f066cbbfc2d242c104f103b33da";
    sha256 = "0cyc4sc2bmsh9l6f1hg7j16944r7azd6yh5fblc8jw4hnhlqd8dp";
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
    rev = "10cf376f07755f066cbbfc2d242c104f103b33da";
    sha256 = "0cyc4sc2bmsh9l6f1hg7j16944r7azd6yh5fblc8jw4hnhlqd8dp";
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
  "mox" = self.lib.mkRacketDerivation rec {
  pname = "mox";
  src = fetchgit {
    name = "mox";
    url = "git://github.com/wargrey/mox.git";
    rev = "9fade3b1dc2ce2b7853f0cdb0a28357c5a435310";
    sha256 = "0xlibgc6phqcfwipbpf8zn063x456lj8r0s02wfdirra7iny5ilk";
  };
  racketThinBuildInputs = [ self."base" self."w3s" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."digimon" self."graphics" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mred-designer" = self.lib.mkRacketDerivation rec {
  pname = "mred-designer";
  src = fetchgit {
    name = "mred-designer";
    url = "git://github.com/Metaxal/MrEd-Designer.git";
    rev = "220833b738a1d46fbe309ea124ef61b825e42e68";
    sha256 = "13nxv1va6bd75al1b2whyhcaz0x0jxyar4z9dhblqrpvxj8g01yk";
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
    rev = "6dbea1523d75a353b56d1bb63fbc15535d57f240";
    sha256 = "0nf36v580n8dd7mpxj1hjhmnal57az08vbx5wjnjd2356aw4nq9n";
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
    rev = "dbb24e40b1be0c0065b7000ccff8e9e5be7eda92";
    sha256 = "0m76zg7bp4m4add8hrpywqik3ml9nswcdwl5zn7cm0z7nxdz8cwn";
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
    rev = "28ea2c1f4e7a92826308c937608d4d91f2ead051";
    sha256 = "15j7r1ydvwq4006qzna362biarw14ra5f4wa27hlvphrmr6ykklj";
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
    rev = "c691ba0ab5ab13aac0f5fe843f3582e6789ee9eb";
    sha256 = "1c2kq7qirkay5hmdpd9kqpqy1wi7dhm191jn2my4y9xixafr00s4";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/mysterx.zip";
    sha1 = "39b332b453a4416735fbf2b92e1c05b51d831c37";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."racket-doc" self."at-exp-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzcom" = self.lib.mkRacketDerivation rec {
  pname = "mzcom";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/mzcom.zip";
    sha1 = "4deaa6d16f927ca72b110e987ab00f59ef48288c";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."scheme-lib" self."racket-doc" self."mysterx" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/mzscheme.zip";
    sha1 = "7e15b656ff9b079d0f1e2cf86a3e16d47e81adac";
  };
  racketThinBuildInputs = [ self."mzscheme-lib" self."mzscheme-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme-doc" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/mzscheme-doc.zip";
    sha1 = "eaee19bd680949577248ae7fb2c21a1358aad4fb";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."compatibility-lib" self."r5rs-lib" self."scheme-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "mzscheme-lib" = self.lib.mkRacketDerivation rec {
  pname = "mzscheme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/mzscheme-lib.zip";
    sha1 = "3a6925004f1405fd0efdbc5d5fdcf0f6b4ba5a69";
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
  "nasa-open-api" = self.lib.mkRacketDerivation rec {
  pname = "nasa-open-api";
  src = fetchgit {
    name = "nasa-open-api";
    url = "git://github.com/m-hugi/nasa-open-api.git";
    rev = "aea1067af82aa4516f192e96bb987751ad2f6316";
    sha256 = "00z14sm710b3s432kdlfzm2j42iafk3d8cg8p86zvxp7mj1sx9r2";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net.zip";
    sha1 = "f66131cd222996525829f10f62e8c52f96725c37";
  };
  racketThinBuildInputs = [ self."net-lib" self."net-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-cookies.zip";
    sha1 = "5f26cf84e8644ed1ed59018495689b587e1a411d";
  };
  racketThinBuildInputs = [ self."net-cookies-lib" self."net-cookies-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-doc" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-cookies-doc.zip";
    sha1 = "6cc635c38fa1bdf03148c8e470cb8d8bf1cc2bc3";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."net-cookies-lib" self."web-server-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-lib" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-cookies-lib.zip";
    sha1 = "eee5699f4862b01648fcdb97dbca1029b8d826b7";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-cookies-test" = self.lib.mkRacketDerivation rec {
  pname = "net-cookies-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-cookies-test.zip";
    sha1 = "1bbc8320fbdd4e8edf9803ab0c4c2160b5960e46";
  };
  racketThinBuildInputs = [ self."base" self."net-cookies-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-doc" = self.lib.mkRacketDerivation rec {
  pname = "net-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-doc.zip";
    sha1 = "b1645f5642270be9027f963065eb3d482ac1af5c";
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
    rev = "fec61684f123f042ae0236e9ee702fb0591bc502";
    sha256 = "1qxx050353180pqagzhk8jlnvki9s7hdzffmplq0dz6csy6hsnzq";
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
    rev = "fec61684f123f042ae0236e9ee702fb0591bc502";
    sha256 = "1qxx050353180pqagzhk8jlnvki9s7hdzffmplq0dz6csy6hsnzq";
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
    rev = "fec61684f123f042ae0236e9ee702fb0591bc502";
    sha256 = "1qxx050353180pqagzhk8jlnvki9s7hdzffmplq0dz6csy6hsnzq";
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
    rev = "fec61684f123f042ae0236e9ee702fb0591bc502";
    sha256 = "1qxx050353180pqagzhk8jlnvki9s7hdzffmplq0dz6csy6hsnzq";
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
    rev = "0f747569e878ef14d1f5d2de527efd02af88fcf9";
    sha256 = "03k3rl74aival4k7b24adavk3anrzs55fjyrl4jfg68l439abry0";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."typed-racket-lib" self."typed-racket-more" self."sha" self."crypto" self."rackunit-lib" self."web-server-lib" self."racket-doc" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-racket-doc" self."option-bind" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-lib" = self.lib.mkRacketDerivation rec {
  pname = "net-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-lib.zip";
    sha1 = "77ad852b4fab36062947073ccf1bb6b829f0a642";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-pem" = self.lib.mkRacketDerivation rec {
  pname = "net-pem";
  src = fetchgit {
    name = "net-pem";
    url = "git://github.com/themetaschemer/net-pem.git";
    rev = "6a2add18192a24118b13d0e652d808c270dd1890";
    sha256 = "1vwr7645l7s990s7kq02bv5ykd3h4i1msyqyygksvwnh7hzb4vds";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "net-test" = self.lib.mkRacketDerivation rec {
  pname = "net-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/net-test.zip";
    sha1 = "231421b5f6e4abc9e208149f6db8bf8be8cd1ad7";
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
    rev = "08353f574489c65907a0dd15c4c1629e18d77027";
    sha256 = "1cgs8zxmn1607adrzxpj3w1bgkfbss0xlyyb939gwmaw70m46505";
  };
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."gregor-lib" self."parser-tools-lib" self."at-exp-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "nproc" = self.lib.mkRacketDerivation rec {
  pname = "nproc";
  src = fetchgit {
    name = "nproc";
    url = "git://github.com/jeroanan/nproc.git";
    rev = "779fe7db83918a6ade7cf27f64d2fd5f9358f8bc";
    sha256 = "150qpja86mfrdwh34qp4l8wddd2cwbkxady8rpnpqd1jiwpa4xc2";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/optimization-coach.zip";
    sha1 = "c1e35ac9e349e30c61182f0c2b8569c5eae5c4f1";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/option-contract.zip";
    sha1 = "1517ebd57034684047cd897218b05b254abc18c9";
  };
  racketThinBuildInputs = [ self."option-contract-lib" self."option-contract-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-doc" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/option-contract-doc.zip";
    sha1 = "0b5ce3405ad1ebd83515fd5f881b8021cf649ac4";
  };
  racketThinBuildInputs = [ self."base" self."option-contract-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-lib" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/option-contract-lib.zip";
    sha1 = "05701766e740fff58cc928c4758ea0b38fca2554";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "option-contract-test" = self.lib.mkRacketDerivation rec {
  pname = "option-contract-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/option-contract-test.zip";
    sha1 = "0ab4e56589346690766d3d89215b0f7e6d1a1d1d";
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
  "otp" = self.lib.mkRacketDerivation rec {
  pname = "otp";
  src = self.lib.extractPath {
    path = "otp";
    src = fetchgit {
    name = "otp";
    url = "git://github.com/yilinwei/otp.git";
    rev = "0757167eac914c45a756c090c4bdf5410080c145";
    sha256 = "00n7fql77x03ax17wmxzjc2f4xs86xllsxxsqww17m713vh8mam9";
  };
  };
  racketThinBuildInputs = [ self."base" self."otp-lib" self."typed-otp-lib" self."otp-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "otp-doc" = self.lib.mkRacketDerivation rec {
  pname = "otp-doc";
  src = self.lib.extractPath {
    path = "otp-doc";
    src = fetchgit {
    name = "otp-doc";
    url = "git://github.com/yilinwei/otp.git";
    rev = "0757167eac914c45a756c090c4bdf5410080c145";
    sha256 = "00n7fql77x03ax17wmxzjc2f4xs86xllsxxsqww17m713vh8mam9";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."scribble-lib" self."otp-lib" self."crypto-lib" self."crypto-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "otp-lib" = self.lib.mkRacketDerivation rec {
  pname = "otp-lib";
  src = self.lib.extractPath {
    path = "otp-lib";
    src = fetchgit {
    name = "otp-lib";
    url = "git://github.com/yilinwei/otp.git";
    rev = "0757167eac914c45a756c090c4bdf5410080c145";
    sha256 = "00n7fql77x03ax17wmxzjc2f4xs86xllsxxsqww17m713vh8mam9";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."rackunit-lib" ];
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
    rev = "785bc9b1eac503c9359d9d08936422f6f47ce82b";
    sha256 = "17arfshzv0vsb8sf3sqr43bpp3hjs55cpz0xym65qnap050ikbqi";
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
    rev = "9c846654947f1605df9b318b202202d2ea3c8baf";
    sha256 = "1sf77ghplpyfrp4ly90w1qix54cpkpcsvnsbwjs95r5pvp3g7yg8";
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
    rev = "9c846654947f1605df9b318b202202d2ea3c8baf";
    sha256 = "1sf77ghplpyfrp4ly90w1qix54cpkpcsvnsbwjs95r5pvp3g7yg8";
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
    rev = "9c846654947f1605df9b318b202202d2ea3c8baf";
    sha256 = "1sf77ghplpyfrp4ly90w1qix54cpkpcsvnsbwjs95r5pvp3g7yg8";
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
    rev = "9c846654947f1605df9b318b202202d2ea3c8baf";
    sha256 = "1sf77ghplpyfrp4ly90w1qix54cpkpcsvnsbwjs95r5pvp3g7yg8";
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
    rev = "0e7e061ecc1709d5ebe0cd4fcbd56597e1e5575f";
    sha256 = "13rxr7npna6h6q9216jl15h3dllj7jg0jdlfiwghbkk9h91agpd0";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/parser-tools.zip";
    sha1 = "6daa0b6f3744c9bdbb23b64fa7da8c8c8c3503f0";
  };
  racketThinBuildInputs = [ self."parser-tools-lib" self."parser-tools-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-tools-doc" = self.lib.mkRacketDerivation rec {
  pname = "parser-tools-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/parser-tools-doc.zip";
    sha1 = "4181518f5af20880da59b0170c7c255adee7560d";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."parser-tools-lib" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "parser-tools-lib" = self.lib.mkRacketDerivation rec {
  pname = "parser-tools-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/parser-tools-lib.zip";
    sha1 = "8d39f78a6c9fc9cbf16155228102884bb12c6878";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pconvert-lib.zip";
    sha1 = "7d709c0b7c41ff28d017d07169687ad5055844aa";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pconvert-test" = self.lib.mkRacketDerivation rec {
  pname = "pconvert-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pconvert-test.zip";
    sha1 = "a1bc2011700a10137bf43d7d53dcad499779fe80";
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
    rev = "cabbb94e5caf786004e9c54dd624fa4ec574998e";
    sha256 = "1gd5292w5075b9qzn56rkdapxv7z3rmx04ga90jjrpq6z8a8hrz4";
  };
  racketThinBuildInputs = [ self."base" self."web-server" self."db-doc" self."db-lib" self."racket-doc" self."scribble-lib" ];
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
    rev = "694c75444c4151be7069b3a0271650921d86ce51";
    sha256 = "129zq6090bf5inqzgxjh522sa2naia1klcmavahnlg8y5nqr7zaf";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict.zip";
    sha1 = "f1cc3534cae01171f5e23ac0273799daf25cb820";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-doc.zip";
    sha1 = "54e14dc49809407c3a6b28decb7cecb17aa326b5";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."draw-lib" self."gui-lib" self."scribble-lib" self."slideshow-lib" self."pict-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-lib" = self.lib.mkRacketDerivation rec {
  pname = "pict-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-lib.zip";
    sha1 = "559d4fd04c8dde5b8e2476a0c51fae53a3b4d18f";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."draw-lib" self."syntax-color-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-snip.zip";
    sha1 = "0d45d622b74d57d7786e122e49ff070ee02d7211";
  };
  racketThinBuildInputs = [ self."pict-snip-lib" self."pict-snip-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-doc" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-snip-doc.zip";
    sha1 = "39cfa004fcb87c89bc32beb888403a654d905568";
  };
  racketThinBuildInputs = [ self."base" self."pict-snip-lib" self."gui-doc" self."pict-doc" self."pict-lib" self."racket-doc" self."scribble-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-lib" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-snip-lib.zip";
    sha1 = "faef52ec81f79d95a84aca37caadd8c79625fb2d";
  };
  racketThinBuildInputs = [ self."draw-lib" self."snip-lib" self."pict-lib" self."wxme-lib" self."base" self."rackunit-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-snip-test" = self.lib.mkRacketDerivation rec {
  pname = "pict-snip-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-snip-test.zip";
    sha1 = "53da658f04a528a0fe80e776ad374328dad72f12";
  };
  racketThinBuildInputs = [ self."base" self."pict-snip-lib" self."draw-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pict-test" = self.lib.mkRacketDerivation rec {
  pname = "pict-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/pict-test.zip";
    sha1 = "d942ae42cda978ca5db1048953fef148e2f76ce6";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/picturing-programs.zip";
    sha1 = "c10538583c11b06de00abdcbf240deeef6706fcb";
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
    rev = "ad93e7f9f9ea70f9dedffb8d64b705c68f38b48c";
    sha256 = "13v381pc9bdsxxs443dvjmys8c1z674k4y7kn27nmss36x5nmxay";
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
    rev = "f39127f1c23c479390d32a8e32502a0dc14b8f7d";
    sha256 = "1s589yqx4hr3lanqhvbm63v057pix7v87kx9v2vybps73db90fr6";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "pkg-build" = self.lib.mkRacketDerivation rec {
  pname = "pkg-build";
  src = fetchgit {
    name = "pkg-build";
    url = "git://github.com/racket/pkg-build.git";
    rev = "31fea3651b501e2ad333cf6133527290abd2eed1";
    sha256 = "0ws6w5shwwr3s5i0x3c7pqmkssqprb125vrnbg1xr66rnsxncyf4";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plai.zip";
    sha1 = "06bc7c832567616bac22dfc9585a89b4669c2da3";
  };
  racketThinBuildInputs = [ self."plai-doc" self."plai-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plai-doc" = self.lib.mkRacketDerivation rec {
  pname = "plai-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plai-doc.zip";
    sha1 = "32590ab8f49e146603fa0f252ef17d3110e462c7";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plai-lib.zip";
    sha1 = "23f2a73fcf4f1cfc75145b125ef35747fd913082";
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
    rev = "32420453c0890a505c4cb4ee13b0fdcc74655a18";
    sha256 = "1avz09dqwjlh0qf5l3lx4wxs6llmfsy51njlhkmj7ai1i43aqzzl";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/planet.zip";
    sha1 = "6dbe3f1239af6ac526065a961b655a9f134defdb";
  };
  racketThinBuildInputs = [ self."planet-lib" self."planet-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-doc" = self.lib.mkRacketDerivation rec {
  pname = "planet-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/planet-doc.zip";
    sha1 = "4431781ea5517ca8ab4ff5d90665b6ec8d20eec6";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."planet-lib" self."scribble-lib" self."base" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-lib" = self.lib.mkRacketDerivation rec {
  pname = "planet-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/planet-lib.zip";
    sha1 = "438c08bb453ca3b34f62f1eacbf73c7f39023aa4";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "planet-test" = self.lib.mkRacketDerivation rec {
  pname = "planet-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/planet-test.zip";
    sha1 = "45a753f27ea82003c71aaea9ed89e827e3aca3e6";
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
    rev = "b880f85effd4520e14b815d1dbe0ff7e71f4aaf8";
    sha256 = "016qbaxlqlm7621vrai8a19zvkxmqh49pp4n6afyd739w2nd1by7";
  };
  racketThinBuildInputs = [ self."snip-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."slideshow-lib" self."chess" self."fancy-app" self."point-free" self."rebellion" self."base" self."pict-doc" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
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
    rev = "26421c7c42656c873c4e0a4fc7f48c0a3ed7770f";
    sha256 = "0ivv7djsw5pv4nz2ffk9d6bvf1kr1nvp3zig9sd5h9avqcncpqqp";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."morsel-lib" self."at-exp-lib" self."db-doc" self."doc-coverage" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot" = self.lib.mkRacketDerivation rec {
  pname = "plot";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot.zip";
    sha1 = "662a18790b0180868bee73b4e974dd1cda61f6f8";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot-compat.zip";
    sha1 = "256e46398f27b4eecf19bef8627eb9daf634543c";
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
    rev = "9bfdc610c1e2677506baa66df576c3ec03ac1a84";
    sha256 = "0xbqi181w308l7z4x1pff2lyxva91smka9kzmh133b31pyvd7kz3";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."pict-lib" self."plot-lib" self."pict-snip-lib" self."plot-gui-lib" self."snip-lib" self."gui-doc" self."pict-snip-doc" self."plot-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-doc" = self.lib.mkRacketDerivation rec {
  pname = "plot-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot-doc.zip";
    sha1 = "c4f22e7a36cb18c4de5572365ec81746e80bbf4c";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."plot-lib" self."plot-gui-lib" self."db-lib" self."draw-lib" self."gui-lib" self."pict-lib" self."plot-compat" self."scribble-lib" self."slideshow-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "plot-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot-gui-lib.zip";
    sha1 = "dd6d5b9885115b8d96eaa2f4fa5fedcbaa733a41";
  };
  racketThinBuildInputs = [ self."base" self."plot-lib" self."math-lib" self."gui-lib" self."snip-lib" self."typed-racket-lib" self."typed-racket-more" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-lib" = self.lib.mkRacketDerivation rec {
  pname = "plot-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot-lib.zip";
    sha1 = "41c058e339ac758fc761d10e46fbd18cf5cfe800";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."pict-lib" self."db-lib" self."srfi-lite-lib" self."typed-racket-lib" self."typed-racket-more" self."compatibility-lib" self."math-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "plot-test" = self.lib.mkRacketDerivation rec {
  pname = "plot-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plot-test.zip";
    sha1 = "1fc389cfbe68c0dc62ea4e1de898de91fb5655e1";
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
    rev = "e8c000f6611833f183f598c9d34380ff9d1bfc96";
    sha256 = "06jyd3l8sm9hvfcfk6xw0v22i49ixlbb9xflr81mnf8rxk4rh7cf";
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
    rev = "a40e841223178254948e216ff31e9bd629a66253";
    sha256 = "1kfng1k4rraak7j3crxwld2p96n38qkwpfpf4nkh0l69jv9fmxcw";
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
    rev = "922bab40b54930a13b8609ee28f3362f5ce1a95f";
    sha256 = "0j9yr85a0a81d7d078jkkmgs2w6isksz7hl6g66567xfprp70fbc";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/plt-web-lib.zip";
    sha1 = "0ad087db53475236e3f6313202472311b11d0c3a";
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
    rev = "a4910a86dc62d1147f3aad94b56cecd6499d7aa6";
    sha256 = "0rp7lw2372mldawk7cmbjdkzqvfmp5hgnvmxnrgs35l9zfffll9q";
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
    rev = "b035e0fb3879d7f88fc08901e55e39112cea29a4";
    sha256 = "1la49lmq7j70lzgsady8d9zba297ykjp9qkyyi5yikpdpiqn75vf";
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
    rev = "791e31277e219d1778ed2deb19cb354375e13627";
    sha256 = "1s9gda8s9mgqh7hy46353xqprbx44fy3ags858i7zhaf5zsn57k1";
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
    rev = "5d9838618ae6d6b8c412eaf30bac4bfa9fcf12c9";
    sha256 = "02762ypw56q0vqwaq3qhnkpgfd5dqzskh2sw7nynk5w9sxfd05h4";
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
    rev = "77a03c86054a5d7a26ed0082215b61162eb8b651";
    sha256 = "0i45gw723cyw75qsb5k0pbvk4n1sk4xmzg6rip2456jllxpqn7h0";
  };
  racketThinBuildInputs = [ self."base" self."portaudio-x86_64-macosx" self."portaudio-x86_64-linux" self."portaudio-x86_64-win32" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "portaudio-x86_64-linux" = self.lib.mkRacketDerivation rec {
  pname = "portaudio-x86_64-linux";
  src = fetchgit {
    name = "portaudio-x86_64-linux";
    url = "git://github.com/jbclements/portaudio-x86_64-linux.git";
    rev = "a6c792790429078a18822f56f388691f8d3db15e";
    sha256 = "1i4qjkj628havzpsclr4r557dg0xdp2jn2rcz2978ljj3qkgx4sd";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "portaudio-x86_64-macosx" = self.lib.mkRacketDerivation rec {
  pname = "portaudio-x86_64-macosx";
  src = fetchgit {
    name = "portaudio-x86_64-macosx";
    url = "git://github.com/jbclements/portaudio-x86_64-macosx.git";
    rev = "efe992725c3c0bb10dec555bb20812285ac94c39";
    sha256 = "1y1jkgl7ddf62ffnqv64bv2aas7ya3dpdpahjnrwb4rgy541g3hw";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "portaudio-x86_64-win32" = self.lib.mkRacketDerivation rec {
  pname = "portaudio-x86_64-win32";
  src = fetchgit {
    name = "portaudio-x86_64-win32";
    url = "git://github.com/jbclements/portaudio-x86_64-win32.git";
    rev = "851aebfca64edd7f7a09a0e93a35ba0b59f92a80";
    sha256 = "0zcxp0vd25yj638n2msk5mny8fa84x82h1jawlmpxdwn0qy2c0cg";
  };
  racketThinBuildInputs = [  ];
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
  "preprocessor" = self.lib.mkRacketDerivation rec {
  pname = "preprocessor";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/preprocessor.zip";
    sha1 = "e73d50d1220408c898c97738af725bf8025c507f";
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
    rev = "f3c82271fe92e8414d203087727a73543465d27e";
    sha256 = "0ixkb04w9hqcj0s6h3nhm1mkpsvcjsxmix90ij5rmimqzld42j96";
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
  "private-in" = self.lib.mkRacketDerivation rec {
  pname = "private-in";
  src = fetchgit {
    name = "private-in";
    url = "git://github.com/camoy/private-in.git";
    rev = "d8a8105a70c8940f6a156dc68d035abbcdd2fe08";
    sha256 = "0wcjg5blwwjx30jk3v5fgj4v0y6nzrz9lr1ikal3qlfj5cmvkgqw";
  };
  racketThinBuildInputs = [ self."base" self."chk-lib" self."rackunit-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile" = self.lib.mkRacketDerivation rec {
  pname = "profile";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/profile.zip";
    sha1 = "1684a0964d2c1711104ecad1c1b5c7e17ac09754";
  };
  racketThinBuildInputs = [ self."profile-lib" self."profile-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-doc" = self.lib.mkRacketDerivation rec {
  pname = "profile-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/profile-doc.zip";
    sha1 = "ff476ac8ae3689f328b17e1b3d10fcd4384516da";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/profile-lib.zip";
    sha1 = "fd36a8845ca136f534124cbdf74e2fb84cd23c96";
  };
  racketThinBuildInputs = [ self."base" self."errortrace-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "profile-test" = self.lib.mkRacketDerivation rec {
  pname = "profile-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/profile-test.zip";
    sha1 = "641f00c469a47bd1ae3451000598f71af703756a";
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
    rev = "cf2a5bd0c3243b4dd3a72093ae5eee8e8291a41d";
    sha256 = "00r8cz60mnizkqdgfkm6sdlq8fa5cpxc0zavrf7cqq6kzqv0b0an";
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
    url = "https://chust.org/repos/racket-protobuf/uv/protobuf-1.1.3.zip";
    sha1 = "2b1006f0a15e36b9dc663bccc55d7ec241ff53d0";
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
    rev = "399657556e22ecaca53c7d3d8310bf22e9394f00";
    sha256 = "0dc8i55byp1j897whdklx9ycm0aqxskd1i8gl91srha57njl3saq";
  };
  };
  racketThinBuildInputs = [ self."punctaffy-doc" self."punctaffy-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "punctaffy-doc" = self.lib.mkRacketDerivation rec {
  pname = "punctaffy-doc";
  src = self.lib.extractPath {
    path = "punctaffy-doc";
    src = fetchgit {
    name = "punctaffy-doc";
    url = "git://github.com/lathe/punctaffy-for-racket.git";
    rev = "399657556e22ecaca53c7d3d8310bf22e9394f00";
    sha256 = "0dc8i55byp1j897whdklx9ycm0aqxskd1i8gl91srha57njl3saq";
  };
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."brag" self."lathe-comforts-doc" self."lathe-comforts-lib" self."lathe-morphisms-doc" self."lathe-morphisms-lib" self."net-doc" self."parendown-doc" self."parendown-lib" self."punctaffy-lib" self."racket-doc" self."ragg" self."scribble-lib" ];
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
    rev = "399657556e22ecaca53c7d3d8310bf22e9394f00";
    sha256 = "0dc8i55byp1j897whdklx9ycm0aqxskd1i8gl91srha57njl3saq";
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
    rev = "399657556e22ecaca53c7d3d8310bf22e9394f00";
    sha256 = "0dc8i55byp1j897whdklx9ycm0aqxskd1i8gl91srha57njl3saq";
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
    rev = "797f643b39c714b8d67e899f659a01dd676a69a1";
    sha256 = "0izgga4xd34g2f7rq4p1dk8jqg9gpf0w0vmm9arb2460nx7d6ybb";
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
  "qtops" = self.lib.mkRacketDerivation rec {
  pname = "qtops";
  src = fetchgit {
    name = "qtops";
    url = "git://github.com/emsenn/qtops.git";
    rev = "ef9950feed1435514911f731303c6e4fd4198ca6";
    sha256 = "1d02a51wll84738daicsknklg8ln8fx2ykg3s6f3ja9flsavrzd3";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quad" = self.lib.mkRacketDerivation rec {
  pname = "quad";
  src = fetchgit {
    name = "quad";
    url = "git://github.com/mbutterick/quad.git";
    rev = "395447f35c2fb9fc7b6199ed185850906d80811d";
    sha256 = "0bfjc3glbc3226siy5hp1nklp9smpvf0y130pmjp0hshh0jgqp7h";
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
    rev = "902eb30fa8f5c0df7910df22c1442ff866b3920d";
    sha256 = "19byi1g8hqsr920a0fs52frv75rykn9ygz8wv2x7jdcmrmk3kaxp";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."doc-coverage" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript" = self.lib.mkRacketDerivation rec {
  pname = "quickscript";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/quickscript.zip";
    sha1 = "35bcbb71e0520a289f0ac5887e67bcddfdfbb9fd";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."drracket-plugin-lib" self."gui-lib" self."net-lib" self."scribble-lib" self."at-exp-lib" self."rackunit-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript-competition-2020" = self.lib.mkRacketDerivation rec {
  pname = "quickscript-competition-2020";
  src = fetchgit {
    name = "quickscript-competition-2020";
    url = "git://github.com/Quickscript-Competiton/July2020entries.git";
    rev = "b6406a4f021671bccb6b464042ba6c91221286fe";
    sha256 = "1aq3pbdp398dkks99n0g2ykfwk1j7byfrqv5an9hilphcapjhsgq";
  };
  racketThinBuildInputs = [ self."data-lib" self."base" self."drracket" self."gui-lib" self."htdp-lib" self."markdown" self."net-lib" self."plot-gui-lib" self."plot-lib" self."quickscript" self."rackunit-lib" self."scribble-lib" self."search-list-box" self."syntax-color-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "quickscript-extra" = self.lib.mkRacketDerivation rec {
  pname = "quickscript-extra";
  src = fetchgit {
    name = "quickscript-extra";
    url = "git://github.com/Metaxal/quickscript-extra.git";
    rev = "cefe55ece00c61e4e762cdc8a012aace76ad42a4";
    sha256 = "1063cfdm48qlqj6hiwy0m2h8may13zz09rbj6gylvmi35sm7r822";
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
    rev = "229a772f74c0a496fae04a5b33aad9ea61c50f5d";
    sha256 = "0ksg0hkysars6baxprj9c877b3mxb29zfjx8p91367ssbabap1zm";
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
  "qweather" = self.lib.mkRacketDerivation rec {
  pname = "qweather";
  src = fetchgit {
    name = "qweather";
    url = "git://github.com/yanyingwang/qweather.git";
    rev = "f9b770d12ec24c102f9346a504dfcf61c6923378";
    sha256 = "1pzzvp6qsckrqrslymfmgki5n48kpgi9yqw9a8ccrvbzvcpc6i6f";
  };
  racketThinBuildInputs = [ self."base" self."at-exp-lib" self."http-client" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r-cade" = self.lib.mkRacketDerivation rec {
  pname = "r-cade";
  src = fetchgit {
    name = "r-cade";
    url = "git://github.com/massung/r-cade.git";
    rev = "593a4490298cfc6346d9f0633803b3e6eb7ed178";
    sha256 = "03q0qcr3acbfkp9dajzv1ay42gqyyy0i1mj2512kx42303dd19c2";
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
    rev = "e41a733b91fc32001d09fe8ff25a0b2c0a06e34c";
    sha256 = "12n600m7za6bhdx1glzfjj3kh2vyjs18s2i517v80vrmxpqh2wam";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r16" = self.lib.mkRacketDerivation rec {
  pname = "r16";
  src = fetchgit {
    name = "r16";
    url = "git://github.com/williewillus/r16.git";
    rev = "6d26fd3e5ab61113b1af6ad743e0c2f2880b6eb3";
    sha256 = "0axixq70cr3pi03j6x8cvphyvk200vmc2f18z5flifxmxps0g0gr";
  };
  racketThinBuildInputs = [ self."base" self."racket-cord" self."sandbox-lib" self."slideshow-lib" self."threading-lib" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs" = self.lib.mkRacketDerivation rec {
  pname = "r5rs";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r5rs.zip";
    sha1 = "c14df8d96ee0d3cb675fb152fe01c6a1a6ebc4b3";
  };
  racketThinBuildInputs = [ self."r5rs-lib" self."r5rs-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs-doc" = self.lib.mkRacketDerivation rec {
  pname = "r5rs-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r5rs-doc.zip";
    sha1 = "9aa60bdc78d8dce89f9948dd91fa8eb946104805";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."scheme-lib" self."scribble-lib" self."r5rs-lib" self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "r5rs-lib" = self.lib.mkRacketDerivation rec {
  pname = "r5rs-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r5rs-lib.zip";
    sha1 = "24dda53109ccdc526be174c31e2bae1e3152b915";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs" = self.lib.mkRacketDerivation rec {
  pname = "r6rs";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r6rs.zip";
    sha1 = "94f2e787638fa7b6fc7f781ff85147145eb62c40";
  };
  racketThinBuildInputs = [ self."r6rs-lib" self."r6rs-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-doc" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r6rs-doc.zip";
    sha1 = "2fcf4d32c5409da959b1742f60bcd64401c0afe9";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."racket-index" self."base" self."scribble-lib" self."r6rs-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-lib" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r6rs-lib.zip";
    sha1 = "15b8a3822d83866bbd68c6f062b60c4916a5aa4f";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."r5rs-lib" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "r6rs-test" = self.lib.mkRacketDerivation rec {
  pname = "r6rs-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/r6rs-test.zip";
    sha1 = "edb7157aa81b8b0f9b8b374d9cdac93af92896ef";
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
    rev = "83cb1db5011ce93df7955538c91e80b8eef2d3a8";
    sha256 = "0kw8vrn6azb4ddkrb4h1616jkxnk60gjk8r7k9m9vg9z6v9cippq";
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
  "racket-aarch64-macosx-3" = self.lib.mkRacketDerivation rec {
  pname = "racket-aarch64-macosx-3";
  src = fetchurl {
    url = "https://pkg-sources.racket-lang.org/pkgs/f0932cc3ef7c5d26b325bc1ac0826811e77a3fc3/racket-aarch64-macosx-3.zip";
    sha1 = "f0932cc3ef7c5d26b325bc1ac0826811e77a3fc3";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-benchmarks" = self.lib.mkRacketDerivation rec {
  pname = "racket-benchmarks";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-benchmarks.zip";
    sha1 = "5d034ee2335e95fbfb653d8c161eac7339df1a6d";
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
    rev = "922bab40b54930a13b8609ee28f3362f5ce1a95f";
    sha256 = "0j9yr85a0a81d7d078jkkmgs2w6isksz7hl6g66567xfprp70fbc";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."scribble-doc" self."distro-build-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-cheat" = self.lib.mkRacketDerivation rec {
  pname = "racket-cheat";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-cheat.zip";
    sha1 = "fdc1b9967a4529ec395a929c385e9d1c6ccb8ebb";
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
    url = "git://github.com/simmsb/racket-cord.git";
    rev = "7bc0decf18dca24c5c5b5cb33de6704026b990a2";
    sha256 = "019rxhblp1sxa9rnqmvb69gxpmwimr5x16v4hjnrv7zn3k2ls3aa";
  };
  racketThinBuildInputs = [ self."base" self."http-easy" self."rfc6455" self."rackunit-lib" self."scribble-lib" self."srfi-lite-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-doc" = self.lib.mkRacketDerivation rec {
  pname = "racket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-doc.zip";
    sha1 = "69eac8c74c86ed594f3e9dd050b971a6a796b2cb";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-i386-macosx-3.zip";
    sha1 = "d406474257172a3cc36b684bf70a96aa6587f9ed";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-index.zip";
    sha1 = "e637a028ff5821af89e1465029d05231d55de027";
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
    rev = "88dada2ee769ada9afaf1e3ec1fb28b8ddf216db";
    sha256 = "1d4ky5ndahrgrljbp6swckmaymmrkg0bs82nprz55dhn7ffflczz";
  };
  racketThinBuildInputs = [ self."slideshow-lib" self."csv-reading" self."typed-racket-lib" self."datalog" self."graph" self."gui-lib" self."base" self."plt-web-lib" self."at-exp-lib" self."net-lib" self."racket-index" self."scribble-lib" self."syntax-color-lib" self."plot-gui-lib" self."plot-lib" self."math-lib" self."pollen" self."css-tools" self."sugar" self."txexpr" self."gregor-lib" self."frog" self."rackunit-lib" self."pict-lib" self."ppict" self."draw-lib" self."s3-sync" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-langserver" = self.lib.mkRacketDerivation rec {
  pname = "racket-langserver";
  src = fetchgit {
    name = "racket-langserver";
    url = "git://github.com/jeapostrophe/racket-langserver.git";
    rev = "b13132e284af977c3a7f6375e76e05f9134a796b";
    sha256 = "0mmq45lyisd9kj91zw199ajrgylcx423bxpdl8i19d07cazh191r";
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
  "racket-paint" = self.lib.mkRacketDerivation rec {
  pname = "racket-paint";
  src = fetchgit {
    name = "racket-paint";
    url = "git://github.com/Metaxal/racket-paint.git";
    rev = "4fe14ce20d77053f4f299cb5123e229d635236cc";
    sha256 = "1di3l5ga28i138i2b0q4mk36mnlrdxi6ww4k3flm63iqq8cqd48a";
  };
  racketThinBuildInputs = [ self."gui-lib" self."pict-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-poppler" = self.lib.mkRacketDerivation rec {
  pname = "racket-poppler";
  src = fetchgit {
    name = "racket-poppler";
    url = "git://github.com/soegaard/racket-poppler.git";
    rev = "0ccd65fb4a85c05ad6494b5ab8412c529bd77f26";
    sha256 = "1x10mbd9pkp5z0xaiwab4wqz1lhdifd4l48wk04kihyc049yy1p6";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-ppc-macosx-3.zip";
    sha1 = "eb122bb4d6efe47f7504ebe9b0bd575d2c797a36";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-predicates" = self.lib.mkRacketDerivation rec {
  pname = "racket-predicates";
  src = fetchgit {
    name = "racket-predicates";
    url = "git://github.com/aryaghan-mutum/racket-predicates.git";
    rev = "3a4f82ffaaf80033bb744e45eb57b05ef5399c99";
    sha256 = "1w5cnczxjy5x3crkgwq3cq411g94pbbrn1zv0yfdgr3jcc5vn85z";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-test.zip";
    sha1 = "b5ed4ca1b4cf4ae808f2e5a9db1621778bf542fc";
  };
  racketThinBuildInputs = [ self."net-test+racket-test" self."compiler-lib" self."sandbox-lib" self."compatibility-lib" self."eli-tester" self."planet-lib" self."net-lib" self."serialize-cstruct-lib" self."cext-lib" self."pconvert-lib" self."racket-test-core" self."web-server-lib" self."rackunit-lib" self."at-exp-lib" self."option-contract-lib" self."srfi-lib" self."scribble-lib" self."racket-index" self."scheme-lib" self."base" self."data-lib" ];
  circularBuildInputs = [ "racket-test" "net-test" ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-test-core" = self.lib.mkRacketDerivation rec {
  pname = "racket-test-core";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-test-core.zip";
    sha1 = "7c2f1ad46c20734a38548fa63accad4585262d16";
  };
  racketThinBuildInputs = [ self."base" self."zo-lib" self."at-exp-lib" self."serialize-cstruct-lib" self."dynext-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racket-test-extra" = self.lib.mkRacketDerivation rec {
  pname = "racket-test-extra";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-test-extra.zip";
    sha1 = "74dc6c6c3a30673878725186eb0673975cbe7827";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-win32-i386-3.zip";
    sha1 = "0dce6ba21894fadb87c4937976afe72b663245c8";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-win32-x86_64-3.zip";
    sha1 = "6b412dc9138287802a4f593fab237e0573ef48b3";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-x86_64-linux-natipkg-3.zip";
    sha1 = "6d47a95774f4bbcd008d0f496d54bfeb9d23bfa8";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racket-x86_64-macosx-3.zip";
    sha1 = "e8c1430ce1ef8ca3fac991eaf68b330e6d3ca987";
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
    rev = "25e64fbe5eaecf5e290b2d3a20c7df31a2e74cb6";
    sha256 = "1mp3cpgg7150wlx8gc9g88d782gx71v9f8xzr2m3da19fsgc6fgp";
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
    rev = "25e64fbe5eaecf5e290b2d3a20c7df31a2e74cb6";
    sha256 = "1mp3cpgg7150wlx8gc9g88d782gx71v9f8xzr2m3da19fsgc6fgp";
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
    rev = "25e64fbe5eaecf5e290b2d3a20c7df31a2e74cb6";
    sha256 = "1mp3cpgg7150wlx8gc9g88d782gx71v9f8xzr2m3da19fsgc6fgp";
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
    rev = "045e0e647439623397cdf67e8e045ec7aa5e2def";
    sha256 = "18m3s9j4iwmi3zh69ig4gi8x9n6c4mr6pz188wvj6cvqlr77axwj";
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
    rev = "62b210b0544c9660cac41b2b8c298b364e73cbee";
    sha256 = "0vawayx777d2y0b0y9v7cxwf38lmlzhvmfhp3diib0490ivldwmc";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."threading-lib" self."rackunit-lib" self."racket-doc" self."sandbox-lib" self."scribble-lib" self."threading-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "racklog" = self.lib.mkRacketDerivation rec {
  pname = "racklog";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/racklog.zip";
    sha1 = "b027a8091c9a4b8b51ae39aebcd8f7af20a872a2";
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
    rev = "5d94185dea482974a1cf66099380bede6c2ce501";
    sha256 = "0gl4jxdg4yl4bdphspy2vacra87skxpij57q5casjjw4ambb3ns7";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."rackunit-lib" self."scheme-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit" = self.lib.mkRacketDerivation rec {
  pname = "rackunit";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit.zip";
    sha1 = "b018dcf59cb4360cbb602b3db0813bf33ec72747";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-doc.zip";
    sha1 = "b4ab62695f4b580d2078f2f325feffe5325a2688";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-gui.zip";
    sha1 = "1366bd4e9dc7c7874c6c20b2c33a674513b524a8";
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."class-iop-lib" self."data-lib" self."gui-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-lib" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-lib.zip";
    sha1 = "0a0cae5523df7fc33849222b863d113f0668670c";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."macrotypes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-plugin-lib" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-plugin-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-plugin-lib.zip";
    sha1 = "a2548e36ba1db863619cf7185474e4277c5a024d";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-test.zip";
    sha1 = "29fef95410f045db72bf35359e839ea67ca9fd7f";
  };
  racketThinBuildInputs = [ self."base" self."eli-tester" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rackunit-typed" = self.lib.mkRacketDerivation rec {
  pname = "rackunit-typed";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/rackunit-typed.zip";
    sha1 = "42650a7ed7eed6a3da32bc31c4d94f3674d723e5";
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
  "raco-run" = self.lib.mkRacketDerivation rec {
  pname = "raco-run";
  src = fetchgit {
    name = "raco-run";
    url = "git://github.com/samdphillips/raco-run.git";
    rev = "a57165d1ba73436476cd9466b74dc1ff71d6b19a";
    sha256 = "0cp1hiil5qa5rvvvj0dcvlaxqjh8j732yx0abb0piav4q04x6xbz";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raco-search" = self.lib.mkRacketDerivation rec {
  pname = "raco-search";
  src = fetchgit {
    name = "raco-search";
    url = "git://github.com/yilinwei/raco-search.git";
    rev = "b5341b696c280f15f8a731008e0f814cc95c2865";
    sha256 = "08j6x9100cypqmvb1y7qr6f592allhcdb1n2r22p0am4qmac3mww";
  };
  racketThinBuildInputs = [ self."base" self."levenshtein" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "raco-watch" = self.lib.mkRacketDerivation rec {
  pname = "raco-watch";
  src = fetchgit {
    name = "raco-watch";
    url = "git://github.com/dannypsnl/raco-watch.git";
    rev = "9cedc2a46a80336b761314a34ef9ec0801b0c5b8";
    sha256 = "0yd7dyz0mc4834nhfcbn5apf1r6hngc1ay52mw2imbdb0ddfgf4b";
  };
  racketThinBuildInputs = [ self."base" self."file-watchers" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "540530c28689de50c526abf36079c07fd0436edb";
    sha256 = "0i2hq46fjxsdmzdv58ck11y7sfm4b8f32jrd20i1rwsxvkr4czaz";
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
    rev = "c40c5adfedf632bc1fdbad3e0e2763b134ee3ff5";
    sha256 = "1jcdlidbp1nq3jh99wsghzmyamfcs5zwljarrwcyfnkmkaxvviqg";
  };
  };
  racketThinBuildInputs = [ self."base" self."basedir" self."shell-pipeline" self."linea" self."udelim" self."scribble-lib" self."scribble-doc" self."racket-doc" self."rackunit-lib" self."readline-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rash-demos" = self.lib.mkRacketDerivation rec {
  pname = "rash-demos";
  src = self.lib.extractPath {
    path = "rash-demos";
    src = fetchgit {
    name = "rash-demos";
    url = "git://github.com/willghatch/racket-rash.git";
    rev = "c40c5adfedf632bc1fdbad3e0e2763b134ee3ff5";
    sha256 = "1jcdlidbp1nq3jh99wsghzmyamfcs5zwljarrwcyfnkmkaxvviqg";
  };
  };
  racketThinBuildInputs = [ self."base" self."rash" self."basedir" self."shell-pipeline" self."linea" self."udelim" self."scribble-lib" self."scribble-doc" self."racket-doc" self."rackunit-lib" self."readline-lib" self."make" self."csv-reading" self."text-table" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/readline.zip";
    sha1 = "70fb9cfca4656fb41e14ce8427397eb83deb09ee";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."readline-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "readline-doc" = self.lib.mkRacketDerivation rec {
  pname = "readline-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/readline-doc.zip";
    sha1 = "dbe33d627e9df23907082f4b3322b04d67bc5b54";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/readline-lib.zip";
    sha1 = "c9bb7158046a6022c91cf13d74fde18be04642ca";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "realm" = self.lib.mkRacketDerivation rec {
  pname = "realm";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/realm.zip";
    sha1 = "e28fd280cb085b9a8cb6058ff5fdc0a44f20368b";
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
    rev = "a7830c71f48b92cd8fe20d98fdb907f1972bd9b0";
    sha256 = "1vydxafagv28b4j4y8z5xn5bqs1qrl77jr02crhdykghq32p2afm";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex.zip";
    sha1 = "f77726c2456bb6b3c8ffda25b77869ea50d7aee5";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-benchmark.zip";
    sha1 = "d902065e05ce257dc076699462f7b71b080ead74";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-doc.zip";
    sha1 = "5212d7236fc2b14e9488f2f5ff88d36647686a22";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."draw-doc" self."gui-doc" self."htdp-doc" self."pict-doc" self."slideshow-doc" self."at-exp-lib" self."data-doc" self."data-enumerate-lib" self."scribble-lib" self."gui-lib" self."htdp-lib" self."pict-lib" self."redex-gui-lib" self."redex-benchmark" self."rackunit-lib" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-etc" = self.lib.mkRacketDerivation rec {
  pname = "redex-etc";
  src = fetchgit {
    name = "redex-etc";
    url = "git://github.com/camoy/redex-etc.git";
    rev = "edda9f8fa70f1f5c6534e4bc3aebb2747c3a801d";
    sha256 = "0zi7jidsh0pmdg7m66hrp3i31qpqcndbk35x47gr4535ivijy36f";
  };
  racketThinBuildInputs = [ self."redex-pict-lib" self."unstable-redex" self."base" self."redex-lib" self."private-in" self."draw-lib" self."pict-lib" self."redex-doc" self."chk-lib" self."racket-doc" self."scribble-lib" self."pict-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-examples" = self.lib.mkRacketDerivation rec {
  pname = "redex-examples";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-examples.zip";
    sha1 = "018be508bef85356b4fb51e78ae0e6f36fb1710b";
  };
  racketThinBuildInputs = [ self."base" self."compiler-lib" self."rackunit-lib" self."redex-gui-lib" self."slideshow-lib" self."math-lib" self."plot-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-gui-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-gui-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-gui-lib.zip";
    sha1 = "82ecd5465bfe86747997001a83295997a8cc6ab7";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."draw-lib" self."gui-lib" self."data-lib" self."profile-lib" self."redex-lib" self."redex-pict-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-lib.zip";
    sha1 = "c3ceb0133fd2ecd731fd8875c1a3d462f5b26a77";
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
    rev = "64518a5d750ca672c0da51f45650f4a255a16a45";
    sha256 = "0cwxpp7v11pmdsbbvpg7wzcwv7ylfddgdgdnpj4z1ymqf9w1jkkq";
  };
  racketThinBuildInputs = [ self."base" self."redex-lib" self."chk-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."redex-doc" self."sandbox-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-pict-lib" = self.lib.mkRacketDerivation rec {
  pname = "redex-pict-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-pict-lib.zip";
    sha1 = "f26910a09fd43d64d9be6c9262709e7c92ac515c";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."draw-lib" self."data-lib" self."profile-lib" self."redex-lib" self."pict-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "redex-test" = self.lib.mkRacketDerivation rec {
  pname = "redex-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/redex-test.zip";
    sha1 = "a9c7785a653725bde6fb714ea306724416706d56";
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
    rev = "0f6c1a723f25f40dd9c6f682dee30fa8a9288f86";
    sha256 = "1ba6awjw7if39pmz1c82ay50a7zzqk6y377pkq02fj2wyayffqnp";
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
    rev = "0f6c1a723f25f40dd9c6f682dee30fa8a9288f86";
    sha256 = "1ba6awjw7if39pmz1c82ay50a7zzqk6y377pkq02fj2wyayffqnp";
  };
  };
  racketThinBuildInputs = [ self."base" self."resource-pool-lib" self."unix-socket-lib" ];
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
    rev = "0f6c1a723f25f40dd9c6f682dee30fa8a9288f86";
    sha256 = "1ba6awjw7if39pmz1c82ay50a7zzqk6y377pkq02fj2wyayffqnp";
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
    rev = "0f6c1a723f25f40dd9c6f682dee30fa8a9288f86";
    sha256 = "1ba6awjw7if39pmz1c82ay50a7zzqk6y377pkq02fj2wyayffqnp";
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
    rev = "db00b7536f64b6f31a15819d7ba5f6783a4f9d31";
    sha256 = "1ghayy3x4xy9zg40pa449r7hf0mfgp2d69cfaj4hzx4dqmmjy5w2";
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
    rev = "1725355df2cd1ffef7e0c8f01cde848d0f3dcfbf";
    sha256 = "1wb1mxv2s923vk9cjw18k37dl6bj167595df91fnpc5gk4qw3xyn";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "relation" = self.lib.mkRacketDerivation rec {
  pname = "relation";
  src = fetchgit {
    name = "relation";
    url = "git://github.com/countvajhula/relation.git";
    rev = "eba916a37511427f54b9d6093f7620600c99c1a7";
    sha256 = "18pn7p3dzfzal0wdbxki9whzffw1z4mixs9gwq98jc3r0s1m1kzd";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."describe" self."functional-lib" self."arguments" self."point-free" self."threading-lib" self."mischief" self."social-contract" self."kw-utils" self."typed-stack" self."version-case" self."rackunit-lib" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."algebraic" self."sugar" self."fancy-app" self."collections-doc" self."functional-doc" self."rackjure" self."threading-doc" self."sandbox-lib" self."cover" self."cover-coveralls" self."at-exp-lib" ];
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
    rev = "cb47dd8b081ad14800fd668898f6f938a4a40e91";
    sha256 = "0g2mv37vml5s80848x0qhf4bqk09rp52a7hmwalkzsgsb56gk2va";
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
    rev = "212b4e1e99f782eba6bbc1141a0b7f8c3272661e";
    sha256 = "0asmzc5376487fh68anvn551rmrwbjimb625k6wdcikm14rhml7i";
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
    rev = "212b4e1e99f782eba6bbc1141a0b7f8c3272661e";
    sha256 = "0asmzc5376487fh68anvn551rmrwbjimb625k6wdcikm14rhml7i";
  };
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."remote-shell-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "remote-shell-lib" = self.lib.mkRacketDerivation rec {
  pname = "remote-shell-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/remote-shell-lib.zip";
    sha1 = "2406bcabb75321e56da43d025525c662c0bc036a";
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
    rev = "3667dd5433f805738b4990828112450c5546fd77";
    sha256 = "0vq3h0c0cl69zcl62v11nbvcg3p1y2ncmzn4lfqrp9418jzqdnkf";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."afl" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "reporter" = self.lib.mkRacketDerivation rec {
  pname = "reporter";
  src = fetchgit {
    name = "reporter";
    url = "git://github.com/racket-tw/reporter.git";
    rev = "e55bc673a0b26b7013354da3bd6fb0e007eac73f";
    sha256 = "11an9sa9sx9hi5apxn365iv69d9b8sykgkzh5cz1lpfrwp910yla";
  };
  racketThinBuildInputs = [ self."base" self."ansi-color" self."typed-racket-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."c-utils" ];
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
    rev = "fa78b05f5f063e767bcdb38a3d46cb4ff911ed56";
    sha256 = "135y5yxwnw3nvcqcwkjvwgmrqqz9b9q9an10knsbv4d5ca4g48li";
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
  "resource-pool" = self.lib.mkRacketDerivation rec {
  pname = "resource-pool";
  src = self.lib.extractPath {
    path = "resource-pool";
    src = fetchgit {
    name = "resource-pool";
    url = "git://github.com/Bogdanp/racket-resource-pool.git";
    rev = "c6e82f0cb610f32beeef700ce897f613cb732fb6";
    sha256 = "0q85lrswxzcqvx7y1ipmpidzxysi739ycbc4zmncm9pajckdam79";
  };
  };
  racketThinBuildInputs = [ self."base" self."resource-pool-lib" self."rackcheck" self."racket-doc" self."rackunit-lib" self."resource-pool-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "resource-pool-lib" = self.lib.mkRacketDerivation rec {
  pname = "resource-pool-lib";
  src = self.lib.extractPath {
    path = "resource-pool-lib";
    src = fetchgit {
    name = "resource-pool-lib";
    url = "git://github.com/Bogdanp/racket-resource-pool.git";
    rev = "c6e82f0cb610f32beeef700ce897f613cb732fb6";
    sha256 = "0q85lrswxzcqvx7y1ipmpidzxysi739ycbc4zmncm9pajckdam79";
  };
  };
  racketThinBuildInputs = [ self."base" ];
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
  "resyntax" = self.lib.mkRacketDerivation rec {
  pname = "resyntax";
  src = fetchgit {
    name = "resyntax";
    url = "git://github.com/jackfirth/resyntax.git";
    rev = "0cca9d870dda624c0aae98c7d44fca2ef5ff7045";
    sha256 = "0x8agi93w94liwlrki72v75pcg1hqcxgyrjb9pyf3cklb337kk5s";
  };
  racketThinBuildInputs = [ self."br-parser-tools-lib" self."brag-lib" self."rackunit-lib" self."gui-lib" self."fancy-app" self."rebellion" self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
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
    rev = "1068767539572ce34ac9f3afc59658e54a21ef00";
    sha256 = "1pbx1sghnrrcmdd9rainsvsbi4iv54ggivgmfqrq8ia7045n1rsy";
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
    rev = "0a71e54539cb40b574f84674769792444691a8cf";
    sha256 = "0hymkj0j6in9jmsmyhcj2nlyanisk561fq5wyk2nclfqkmf9kjmr";
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
    rev = "ce01d0b08fd421cf70c8e953d82f5c267b78a328";
    sha256 = "144fxrfbmgd3i7k7kqxj8qd291r17f6093zvjw4p8frmjcsbqg2s";
  };
  racketThinBuildInputs = [ self."base" self."math-lib" self."rackunit-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rktermios" = self.lib.mkRacketDerivation rec {
  pname = "rktermios";
  src = fetchgit {
    name = "rktermios";
    url = "https://gitlab.com/racketeer/rktermios.git";
    rev = "cbcdd5b15542bf6f45907e6a6ba2932f0c4cd501";
    sha256 = "0skggv0c45a8hq5w0cwx5v5wvzijifvyma4iipvkych3yb9qxkbr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."scribble-lib" self."racket-doc" self."at-exp-lib" ];
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
    rev = "8f3ca8b47e552911054f2aa12b296dbf40dad637";
    sha256 = "0bs3i7jfjr16byylhs9fxhir2ng0h0qg624qb57n5ysa0as0azd0";
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
    rev = "c3e5bb8a84142b870943b46fbd356171a5c6593c";
    sha256 = "187a9ga3blik950jh6xkhkrwl4qb2lp37cp428zwm7vhpd89g0xk";
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
    rev = "a64e2bccfe5876c5daaf4a17c5a28a49e2fbd501";
    sha256 = "0c1az5rvq2d4a5wnqp67qmmawlhiqq4fc4n1w7gxxadn8z2vvf5d";
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
  "rparallel" = self.lib.mkRacketDerivation rec {
  pname = "rparallel";
  src = fetchgit {
    name = "rparallel";
    url = "https://codeberg.org/montanari/rparallel.git";
    rev = "28a7a131aada4d8d9a7890721a32180a03037624";
    sha256 = "1r99nhl0z7q5ppifbcd7r0d0zq4xlizw0hilns1h8brn5f8fdvfr";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rpn" = self.lib.mkRacketDerivation rec {
  pname = "rpn";
  src = fetchgit {
    name = "rpn";
    url = "git://github.com/jackfirth/rpn.git";
    rev = "74ef351cae43bb64ba35a937f7a2ea664a82abdd";
    sha256 = "0lhbz9ywbzrgm36p30v65r3d511k7w71pd4s0wjpcnm5mkb2z625";
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
    rev = "d9cb3a15e7416df7c2a0a29748cb2f07f1dace32";
    sha256 = "0pwj5ckrsr16wnm2j20gy8q00n5ikyqwxfrwl84ypfgk993wmwdb";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."rtmidi" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rs-l" = self.lib.mkRacketDerivation rec {
  pname = "rs-l";
  src = fetchgit {
    name = "rs-l";
    url = "git://github.com/mcdejonge/rs-l.git";
    rev = "43616cd03e53b0109826736b461086b7146ed971";
    sha256 = "0s6ggcixgk7h6jlwi5j0d7856rg0rdy2aaafd84mg06h2lcbr9ay";
  };
  racketThinBuildInputs = [ self."base" self."rackunit" self."rs" self."scribble-lib" self."racket-doc" ];
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
    rev = "c699db1ffae4cf0185c46bdc059d7879d40614ce";
    sha256 = "07fqlbbgpl98q3xc92z66j4fbq5pn95dwzjsd469f31rz7zhnsqr";
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
    rev = "11879d2e6a3eea7d1766d58123fe89363831313f";
    sha256 = "1xbjwdc2j8iyf6khvli1dfr0qijcm7yjmf0gvi5drp4c8lq3c96c";
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
  "runomatic" = self.lib.mkRacketDerivation rec {
  pname = "runomatic";
  src = fetchgit {
    name = "runomatic";
    url = "git://github.com/winny-/runomatic.git";
    rev = "1043169259980f6092ba2aa13d370c13953c5955";
    sha256 = "0rmjn1drahqnszhqwgvqkjk83wd2b888m7kycak2mwfn94kfhwa3";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."gregor" self."request" self."sxml" ];
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
  "russian-lang" = self.lib.mkRacketDerivation rec {
  pname = "russian-lang";
  src = fetchgit {
    name = "russian-lang";
    url = "git://github.com/Kalimehtar/russian-lang.git";
    rev = "a9660a0777dfdfb2a86aaea22b297c6b769817df";
    sha256 = "0ccklg5ig29a082w8mnx88i3kpacyc8lykn4v0jvwapkydh6z1bf";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "rwind" = self.lib.mkRacketDerivation rec {
  pname = "rwind";
  src = fetchgit {
    name = "rwind";
    url = "git://github.com/Metaxal/rwind.git";
    rev = "5a4f580b0882452f3938aaa1711a6d99570f006f";
    sha256 = "1wj3q1n1wk6bj6a6z7m9r3iisyxm1akwrapkfd8zq92ic6zxp66d";
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
  "sameday" = self.lib.mkRacketDerivation rec {
  pname = "sameday";
  src = fetchgit {
    name = "sameday";
    url = "git://github.com/Bogdanp/racket-sameday.git";
    rev = "20cfc789bacc21941317828496cf15a6a89feee6";
    sha256 = "1kw54yipca62i58d788lkp0pkxwiz5q6cj4d8jqc0gzvgckk29r1";
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."http-easy" self."gregor-doc" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sandbox-lib" = self.lib.mkRacketDerivation rec {
  pname = "sandbox-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sandbox-lib.zip";
    sha1 = "85b70dba0429c584fc2b2ddbfe93a34a5636c9a0";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."errortrace-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl" = self.lib.mkRacketDerivation rec {
  pname = "sasl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sasl.zip";
    sha1 = "c18570ae92646a810c36e2b651ab98d1ff0dce46";
  };
  racketThinBuildInputs = [ self."sasl-lib" self."sasl-doc" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-doc" = self.lib.mkRacketDerivation rec {
  pname = "sasl-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sasl-doc.zip";
    sha1 = "906fcfd0cafb88a1895523324fef9deb4050a14e";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."sasl-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-lib" = self.lib.mkRacketDerivation rec {
  pname = "sasl-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sasl-lib.zip";
    sha1 = "03473f798300ef1a9f0de857de0761a37fb3d6b7";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sasl-test" = self.lib.mkRacketDerivation rec {
  pname = "sasl-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sasl-test.zip";
    sha1 = "fd9e8f3bf345a36289a7efb0795958606bc389eb";
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
    rev = "f4784d0da02012976c68034c284ba3cfe55bf428";
    sha256 = "02q0ybni38gdda022lsn2qnlw1abhxhk0hvjakln27g9b8pzwgd4";
  };
  };
  racketThinBuildInputs = [ self."base" self."libsass-i386-win32" self."libsass-x86_64-linux" self."libsass-x86_64-macosx" self."libsass-x86_64-win32" self."racket-doc" self."rackunit-lib" self."scribble-lib" self."libsass-i386-win32" self."libsass-x86_64-linux" self."libsass-x86_64-macosx" self."libsass-x86_64-win32" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "satore" = self.lib.mkRacketDerivation rec {
  pname = "satore";
  src = self.lib.extractPath {
    path = "satore";
    src = fetchgit {
    name = "satore";
    url = "git://github.com/deepmind/deepmind-research.git";
    rev = "af3aa09cfecc309a46f40a21ceb7d518bd132817";
    sha256 = "1qnxv2ihzacabbaf66g3nhjyxdlbrs0j3a81hjzn0q0k7gp5f4wd";
  };
  };
  racketThinBuildInputs = [ self."bazaar" self."data-lib" self."define2" self."global" self."math-lib" self."text-table" self."base" self."rackunit-lib" self."scribble-lib" ];
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
  "sauron" = self.lib.mkRacketDerivation rec {
  pname = "sauron";
  src = fetchgit {
    name = "sauron";
    url = "git://github.com/racket-tw/sauron.git";
    rev = "27ba4f9d5e36d809867e82cb80c563549a7f35f8";
    sha256 = "1yfndqhvlfifj1m4r38dbclc6v33w69d0icrrlc4ygwlhg9j4hr8";
  };
  racketThinBuildInputs = [ self."base" self."gui-lib" self."net-lib" self."drracket" self."drracket-plugin-lib" self."drracket-tool-lib" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."gui-doc" ];
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
    rev = "4824a1fecea1dc557941b08f05a457da9f628f78";
    sha256 = "1nhyj59difb1kdis8a3xjj7937ngwdnw1gmaqdmqhx8nv0965q4v";
  };
  racketThinBuildInputs = [ self."base" self."db-lib" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scheme-lib" = self.lib.mkRacketDerivation rec {
  pname = "scheme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scheme-lib.zip";
    sha1 = "a19763ae58c6f92b575c549678241babbd0cf71c";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "schemeunit" = self.lib.mkRacketDerivation rec {
  pname = "schemeunit";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/schemeunit.zip";
    sha1 = "219f1bc6fec4f172043c48134ecd8a50e5c7c932";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."rackunit-gui" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sci" = self.lib.mkRacketDerivation rec {
  pname = "sci";
  src = fetchgit {
    name = "sci";
    url = "git://github.com/soegaard/sci.git";
    rev = "e2f6a50e551f01e8174e80d5a9c3eb480eb7e594";
    sha256 = "192v8i1d5z3wja0xdk71wa7qc9q7vq6ackr4cqm578i909akd7g9";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."scribble-math" self."math-doc" self."racket-doc" self."linux-shared-libraries" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scope-operations" = self.lib.mkRacketDerivation rec {
  pname = "scope-operations";
  src = fetchgit {
    name = "scope-operations";
    url = "git://github.com/jsmaniac/scope-operations.git";
    rev = "5ea8f32528bcf1ed4393cf9a054920936c27a556";
    sha256 = "1f7z7bljxx3019x451rdhdicj9zihqfwkmfs814r3vgjxdal1qhb";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble.zip";
    sha1 = "a5cb923ee68ca75f7c38fa292d0676fd864ce4d8";
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
  "scribble-bettergrammar" = self.lib.mkRacketDerivation rec {
  pname = "scribble-bettergrammar";
  src = self.lib.extractPath {
    path = "scribble-bettergrammar";
    src = fetchgit {
    name = "scribble-bettergrammar";
    url = "git://github.com/wilbowma/scribble-bettergrammar.git";
    rev = "e7abc41d989f7c777d4e1c2b20b30569177c75f5";
    sha256 = "17w99ggcn0a0la1907g60kx08dh2gcs77sqv7sgmx6rrp0mhh0qk";
  };
  };
  racketThinBuildInputs = [ self."scribble-bettergrammar-lib" self."scribble-bettergrammar-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-bettergrammar-doc" = self.lib.mkRacketDerivation rec {
  pname = "scribble-bettergrammar-doc";
  src = self.lib.extractPath {
    path = "scribble-bettergrammar-doc";
    src = fetchgit {
    name = "scribble-bettergrammar-doc";
    url = "git://github.com/wilbowma/scribble-bettergrammar.git";
    rev = "e7abc41d989f7c777d4e1c2b20b30569177c75f5";
    sha256 = "17w99ggcn0a0la1907g60kx08dh2gcs77sqv7sgmx6rrp0mhh0qk";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-bettergrammar-lib" self."base" self."scribble-lib" self."racket-doc" self."scribble-doc" self."sexp-diff-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-bettergrammar-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-bettergrammar-lib";
  src = self.lib.extractPath {
    path = "scribble-bettergrammar-lib";
    src = fetchgit {
    name = "scribble-bettergrammar-lib";
    url = "git://github.com/wilbowma/scribble-bettergrammar.git";
    rev = "e7abc41d989f7c777d4e1c2b20b30569177c75f5";
    sha256 = "17w99ggcn0a0la1907g60kx08dh2gcs77sqv7sgmx6rrp0mhh0qk";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."sexp-diff-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble-doc.zip";
    sha1 = "75fc2487c34972216972c28170e27132ea73486d";
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
    rev = "d4fe76d1899b540e2806520a3acbf4afdf5abb88";
    sha256 = "1qk2rqwwpaf89ahi9qqi6l5d1c3rn56lnh0x7nji9wa6aisd4200";
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
    rev = "5ba86188de0ce1cd3d4540982be2473183c78e81";
    sha256 = "122ya76qln4fvfc5615vbssps9b2hjpd2nc7j5dk2wssfrkxvswk";
  };
  racketThinBuildInputs = [ self."base" self."gregor" self."timable" self."frog" self."at-exp-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-html-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-html-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble-html-lib.zip";
    sha1 = "312698505f94222be672038938cef024f20f8f1f";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."at-exp-lib" self."scribble-text-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble-lib.zip";
    sha1 = "a103fc2974188b3d007fd4e38f424e3498993ffb";
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
    rev = "a69b6fad193757de5a62b6a1cabacb7557d02ff7";
    sha256 = "07lpb8gh8spd29fmlm70zr5cckjp21z3sn2xnbvdvm25mi98qjg2";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."scribble-lib" self."racket-doc" self."at-exp-lib" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-minted" = self.lib.mkRacketDerivation rec {
  pname = "scribble-minted";
  src = self.lib.extractPath {
    path = "scribble-minted";
    src = fetchgit {
    name = "scribble-minted";
    url = "git://github.com/wilbowma/scribble-minted.git";
    rev = "0639c54c84c3294e575c1e70b2d17f5537c1750a";
    sha256 = "15pad2wn56bncifrrlw9h7i5d1wqgw95nhp5gmmkn1qbkm0nglys";
  };
  };
  racketThinBuildInputs = [ self."scribble-minted-lib" self."scribble-minted-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-minted-doc" = self.lib.mkRacketDerivation rec {
  pname = "scribble-minted-doc";
  src = self.lib.extractPath {
    path = "scribble-minted-doc";
    src = fetchgit {
    name = "scribble-minted-doc";
    url = "git://github.com/wilbowma/scribble-minted.git";
    rev = "0639c54c84c3294e575c1e70b2d17f5537c1750a";
    sha256 = "15pad2wn56bncifrrlw9h7i5d1wqgw95nhp5gmmkn1qbkm0nglys";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."scribble-minted-lib" self."racket-doc" self."scribble-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-minted-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-minted-lib";
  src = self.lib.extractPath {
    path = "scribble-minted-lib";
    src = fetchgit {
    name = "scribble-minted-lib";
    url = "git://github.com/wilbowma/scribble-minted.git";
    rev = "0639c54c84c3294e575c1e70b2d17f5537c1750a";
    sha256 = "15pad2wn56bncifrrlw9h7i5d1wqgw95nhp5gmmkn1qbkm0nglys";
  };
  };
  racketThinBuildInputs = [ self."rackunit-lib" self."scribble-lib" self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-slideshow" = self.lib.mkRacketDerivation rec {
  pname = "scribble-slideshow";
  src = self.lib.extractPath {
    path = "scribble-slideshow";
    src = fetchgit {
    name = "scribble-slideshow";
    url = "git://github.com/rmculpepper/scribble-slideshow.git";
    rev = "884ba101233d06c1f636aa4f2f7643f9b4e10557";
    sha256 = "146bbrfpwpamh91x49fzr33342yxlhzrxr7lsdhk2yj38ikqi3jy";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-slideshow-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-slideshow-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-slideshow-lib";
  src = self.lib.extractPath {
    path = "scribble-slideshow-lib";
    src = fetchgit {
    name = "scribble-slideshow-lib";
    url = "git://github.com/rmculpepper/scribble-slideshow.git";
    rev = "884ba101233d06c1f636aa4f2f7643f9b4e10557";
    sha256 = "146bbrfpwpamh91x49fzr33342yxlhzrxr7lsdhk2yj38ikqi3jy";
  };
  };
  racketThinBuildInputs = [ self."pict-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-test" = self.lib.mkRacketDerivation rec {
  pname = "scribble-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble-test.zip";
    sha1 = "6813f380823d2d7cc7de7a3c3a095bf1a5964d2e";
  };
  racketThinBuildInputs = [ self."at-exp-lib" self."base" self."eli-tester" self."rackunit-lib" self."sandbox-lib" self."scribble-doc" self."scribble-lib" self."scribble-text-lib" self."racket-index" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "scribble-text-lib" = self.lib.mkRacketDerivation rec {
  pname = "scribble-text-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/scribble-text-lib.zip";
    sha1 = "817c9ad5450aec2d7fcdbe217a134b535d32f4fb";
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
    rev = "da39d02302cad3e07c12215e42ea63212d209d1b";
    sha256 = "1sanpk2wybmgcpxv1bxyy90xxsav4zqh0xjpsmvcldrzwzi43ynh";
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
    rev = "a25bfa28e32c60f8219eb712255fa5b07e3a8ad5";
    sha256 = "0piwzqdzg7jnf25i64scnapva4d1s3rai7gmfrfcjf1lblfr88hw";
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
  "search-list-box" = self.lib.mkRacketDerivation rec {
  pname = "search-list-box";
  src = fetchgit {
    name = "search-list-box";
    url = "git://github.com/Metaxal/search-list-box.git";
    rev = "b54b28d4bd8d2d2426d3e211570a811ea3421f5b";
    sha256 = "14yvb69kl4mgbifnx29xh2imx4ii42smswmmvrd35py27nxihkg3";
  };
  racketThinBuildInputs = [ self."gui-lib" self."base" self."gui-doc" self."pict-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "54db05b04b17c3b74facea8e8a438c73d238936a";
    sha256 = "1ifwv6ri749zgq7vr8izvaji4wrifwj6id5hvbcz04vp17fb549x";
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
    rev = "fee107ee2401b5f7d7d797258eab3062ddb71232";
    sha256 = "0ma4rzbd4jdb0vixy7gcivbw6vk7rswhlmb2nw4fbbyj7s43rcm3";
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
  "sendinblue" = self.lib.mkRacketDerivation rec {
  pname = "sendinblue";
  src = self.lib.extractPath {
    path = "sendinblue";
    src = fetchgit {
    name = "sendinblue";
    url = "git://github.com/sxn/racket-sendinblue.git";
    rev = "caa2e2afb3c2e43849aed92bcb73deadf0d0d20c";
    sha256 = "076vm7rvzlvw60l8wnsfb6r7drva7knb15vla9vzcimw3ackxa03";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sendinblue-test" = self.lib.mkRacketDerivation rec {
  pname = "sendinblue-test";
  src = self.lib.extractPath {
    path = "sendinblue-test";
    src = fetchgit {
    name = "sendinblue-test";
    url = "git://github.com/sxn/racket-sendinblue.git";
    rev = "caa2e2afb3c2e43849aed92bcb73deadf0d0d20c";
    sha256 = "076vm7rvzlvw60l8wnsfb6r7drva7knb15vla9vzcimw3ackxa03";
  };
  };
  racketThinBuildInputs = [ self."base" self."sendinblue" self."rackunit-lib" self."web-server-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/serialize-cstruct-lib.zip";
    sha1 = "227b13a1a49ec7805c1d9082724c471bd5e46a9a";
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
  src = self.lib.extractPath {
    path = "sexp-diff";
    src = fetchgit {
    name = "sexp-diff";
    url = "git://github.com/stamourv/sexp-diff.git";
    rev = "5791264cb7031308b81c8c91df457cd51888210f";
    sha256 = "1zijgkyramhg71g5dz12vr0x429dagav8q4is5lhi7ps70kadm0v";
  };
  };
  racketThinBuildInputs = [ self."sexp-diff-lib" self."sexp-diff-doc" self."sexp-diff-test" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sexp-diff-doc" = self.lib.mkRacketDerivation rec {
  pname = "sexp-diff-doc";
  src = self.lib.extractPath {
    path = "sexp-diff-doc";
    src = fetchgit {
    name = "sexp-diff-doc";
    url = "git://github.com/stamourv/sexp-diff.git";
    rev = "5791264cb7031308b81c8c91df457cd51888210f";
    sha256 = "1zijgkyramhg71g5dz12vr0x429dagav8q4is5lhi7ps70kadm0v";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."rackunit-lib" self."racket-doc" self."sexp-diff-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sexp-diff-lib" = self.lib.mkRacketDerivation rec {
  pname = "sexp-diff-lib";
  src = self.lib.extractPath {
    path = "sexp-diff-lib";
    src = fetchgit {
    name = "sexp-diff-lib";
    url = "git://github.com/stamourv/sexp-diff.git";
    rev = "5791264cb7031308b81c8c91df457cd51888210f";
    sha256 = "1zijgkyramhg71g5dz12vr0x429dagav8q4is5lhi7ps70kadm0v";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sexp-diff-test" = self.lib.mkRacketDerivation rec {
  pname = "sexp-diff-test";
  src = self.lib.extractPath {
    path = "sexp-diff-test";
    src = fetchgit {
    name = "sexp-diff-test";
    url = "git://github.com/stamourv/sexp-diff.git";
    rev = "5791264cb7031308b81c8c91df457cd51888210f";
    sha256 = "1zijgkyramhg71g5dz12vr0x429dagav8q4is5lhi7ps70kadm0v";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."sexp-diff-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sfont" = self.lib.mkRacketDerivation rec {
  pname = "sfont";
  src = fetchgit {
    name = "sfont";
    url = "git://github.com/danielecapo/sfont.git";
    rev = "c854f9734f15f4c7cd4b98e041b8c961faa3eef2";
    sha256 = "06rj65b67lk0lg2vkc7aqc9r6n55plc3k6gn01z417ia9a8961qb";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" self."gui-lib" self."slideshow-lib" self."pict-doc" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "sgl" = self.lib.mkRacketDerivation rec {
  pname = "sgl";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/sgl.zip";
    sha1 = "d67a8532d0080acc95ed37dcfee8f524d7b50ff5";
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
    rev = "034302a567381e97b3b3956740f97ed3ae629374";
    sha256 = "1rk19hsxj9i4jqdaygp2clpw174b2jlvn49j7kchlax5b43bmwmx";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "shell-completion" = self.lib.mkRacketDerivation rec {
  pname = "shell-completion";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/shell-completion.zip";
    sha1 = "d986efb5dd16f5d75d93a2ba4899ccea914d7e1c";
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
    rev = "c40c5adfedf632bc1fdbad3e0e2763b134ee3ff5";
    sha256 = "1jcdlidbp1nq3jh99wsghzmyamfcs5zwljarrwcyfnkmkaxvviqg";
  };
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "shlex" = self.lib.mkRacketDerivation rec {
  pname = "shlex";
  src = fetchgit {
    name = "shlex";
    url = "git://github.com/sorawee/shlex.git";
    rev = "f469d9aee8bdba095d7147928223dd9e98d4dbdc";
    sha256 = "1i81vj2mv2j31a1fl1lhzh28pfgi7lf6v34k3h4a6y60cw41qfgs";
  };
  racketThinBuildInputs = [ self."parser-tools-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    rev = "4af740f085fcae86436c8ef48c11161f5a46deee";
    sha256 = "1b3b48b6q3f04a84jvh66swrhqbzzw93avv9q7aynrrcvaqx32r7";
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
    rev = "4afa806ff27de8e2715b15904e1f3fcec2c7f136";
    sha256 = "00bhn4xb8lwi2virhyh4g7bbag2i6x5w2b23pczcbng555dd6pfh";
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
    rev = "cf15bfd0c71f3dd3189417dd1a7a34fc6bfad557";
    sha256 = "1rld9xcq7q9hnyb7kipp2m3gxgwv1wqf07s7cd52wmp808azv0aa";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."html-parsing" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-matrix" = self.lib.mkRacketDerivation rec {
  pname = "simple-matrix";
  src = fetchgit {
    name = "simple-matrix";
    url = "https://bitbucket.org/derend/simple-matrix.git";
    rev = "19814fd5de10d42eea207939169ee5100e38c500";
    sha256 = "1rpizdficahginds7rscdayphcbkam6ai79f1gp2zy35p0hihf6j";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."rackunit-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-oauth2" = self.lib.mkRacketDerivation rec {
  pname = "simple-oauth2";
  src = fetchgit {
    name = "simple-oauth2";
    url = "git://github.com/johnstonskj/simple-oauth2.git";
    rev = "b8cb40511f64dcb274e17957e6fc9ab4c8a6cbea";
    sha256 = "19xflf53x5g8snryy084a566k6lmkykwhc2xkzghhvlbdmfm9xkm";
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."dali" self."net-jwt" self."threading" self."web-server-lib" self."rackunit-lib" self."rackunit-spec" self."scribble-lib" self."racket-doc" self."racket-index" self."sandbox-lib" self."cover-coveralls" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-obfuscation" = self.lib.mkRacketDerivation rec {
  pname = "simple-obfuscation";
  src = fetchgit {
    name = "simple-obfuscation";
    url = "git://github.com/rfindler/simple-obfuscation.git";
    rev = "f6ff1afe75ae97994b351a9dc189c0e31d06fdf6";
    sha256 = "1hns0fnnhp9nvvakp9n2zsf0m1pnicr7p7i9r3z6girhykzx642s";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-polynomial" = self.lib.mkRacketDerivation rec {
  pname = "simple-polynomial";
  src = fetchgit {
    name = "simple-polynomial";
    url = "https://bitbucket.org/derend/simple-polynomial.git";
    rev = "c8c7e2e4175a27123becd6e78f792738b0bf1188";
    sha256 = "06r5jijpg5fknkyw57fvpmzvyq58xiv3m5gf0gq7lp63kz02ppy6";
  };
  racketThinBuildInputs = [ self."base" self."parser-tools-lib" self."simple-matrix" self."math-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."plot-doc" self."plot-gui-lib" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-qr" = self.lib.mkRacketDerivation rec {
  pname = "simple-qr";
  src = fetchgit {
    name = "simple-qr";
    url = "git://github.com/simmone/racket-simple-qr.git";
    rev = "904f1491bc521badeafeabd0d7d7e97e3d0ee958";
    sha256 = "0n7al3dkz8s7yszdhabvvaghay50hvpxfbr6ycishkmjxn6hb6x4";
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
    rev = "d2fa88b5c0b801bbd6169274237a0edb63998c76";
    sha256 = "1xbpi32hzi3id2aizfi9xhwqynp0xxlzdnnkql3ig674q849gp9y";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-tree-text-markup" = self.lib.mkRacketDerivation rec {
  pname = "simple-tree-text-markup";
  src = self.lib.extractPath {
    path = "simple-tree-text-markup";
    src = fetchgit {
    name = "simple-tree-text-markup";
    url = "git://github.com/racket/simple-tree-text-markup.git";
    rev = "6c91fafc4595e2a1702f291f7b081b433567aaf0";
    sha256 = "1j6sb0jrs11gxn03wn982bls6p1n8inxca6rvfapzcry2ba4b2lv";
  };
  };
  racketThinBuildInputs = [ self."simple-tree-text-markup-lib" self."simple-tree-text-markup-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-tree-text-markup-doc" = self.lib.mkRacketDerivation rec {
  pname = "simple-tree-text-markup-doc";
  src = self.lib.extractPath {
    path = "simple-tree-text-markup-doc";
    src = fetchgit {
    name = "simple-tree-text-markup-doc";
    url = "git://github.com/racket/simple-tree-text-markup.git";
    rev = "6c91fafc4595e2a1702f291f7b081b433567aaf0";
    sha256 = "1j6sb0jrs11gxn03wn982bls6p1n8inxca6rvfapzcry2ba4b2lv";
  };
  };
  racketThinBuildInputs = [ self."base" self."scheme-lib" self."at-exp-lib" self."scribble-lib" self."racket-doc" self."simple-tree-text-markup-lib" self."draw-doc" self."draw-lib" self."gui-doc" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-tree-text-markup-lib" = self.lib.mkRacketDerivation rec {
  pname = "simple-tree-text-markup-lib";
  src = self.lib.extractPath {
    path = "simple-tree-text-markup-lib";
    src = fetchgit {
    name = "simple-tree-text-markup-lib";
    url = "git://github.com/racket/simple-tree-text-markup.git";
    rev = "6c91fafc4595e2a1702f291f7b081b433567aaf0";
    sha256 = "1j6sb0jrs11gxn03wn982bls6p1n8inxca6rvfapzcry2ba4b2lv";
  };
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-tree-text-markup-test" = self.lib.mkRacketDerivation rec {
  pname = "simple-tree-text-markup-test";
  src = self.lib.extractPath {
    path = "simple-tree-text-markup-test";
    src = fetchgit {
    name = "simple-tree-text-markup-test";
    url = "git://github.com/racket/simple-tree-text-markup.git";
    rev = "6c91fafc4595e2a1702f291f7b081b433567aaf0";
    sha256 = "1j6sb0jrs11gxn03wn982bls6p1n8inxca6rvfapzcry2ba4b2lv";
  };
  };
  racketThinBuildInputs = [ self."base" self."simple-tree-text-markup-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-xlsx" = self.lib.mkRacketDerivation rec {
  pname = "simple-xlsx";
  src = fetchgit {
    name = "simple-xlsx";
    url = "git://github.com/simmone/racket-simple-xlsx.git";
    rev = "4db2b2eb3e66f1bbc4c8cfff268697085891a9bc";
    sha256 = "1bv4z1algk0p6nc47pcsq6v5799kim9hpx4dhwqq8zcnjjmnj7kr";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."racket-doc" self."scribble-lib" self."rackunit-lib" self."at-exp-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "simple-xml" = self.lib.mkRacketDerivation rec {
  pname = "simple-xml";
  src = fetchgit {
    name = "simple-xml";
    url = "git://github.com/simmone/racket-simple-xml.git";
    rev = "ce4fbc007f60bc18d33a2f467099dfdadf6c47b1";
    sha256 = "1ri6ph16wsldfqgx5fpid819sa5x58qrv4v72xj5lqcncprn3vas";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."racket-doc" self."scribble-lib" self."detail" ];
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
    rev = "5a08636d126ea04b5c903ab42a6e7eb2b143d864";
    sha256 = "01nr54jyp6mh2gshdzmm3r5svg6ghfx3vlvmfhmgxlf162l38vli";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slatex.zip";
    sha1 = "6aa52093d9aec763d717e050ff1e51e3a6016727";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."racket-index" self."eli-tester" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow" = self.lib.mkRacketDerivation rec {
  pname = "slideshow";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slideshow.zip";
    sha1 = "c8d38147655c9d4cc7f9840b339e4dc3ccc0ea74";
  };
  racketThinBuildInputs = [ self."slideshow-lib" self."slideshow-exe" self."slideshow-plugin" self."slideshow-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-doc" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slideshow-doc.zip";
    sha1 = "1d2591c527540f0c3b81fe2d34cacefdc3150e74";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."gui-lib" self."pict-lib" self."scribble-lib" self."slideshow-lib" self."at-exp-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-exe" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-exe";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slideshow-exe.zip";
    sha1 = "914c5d885a3e1a51c103146d28e62b5225ddbc81";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slideshow-lib.zip";
    sha1 = "1a06b9f63e548a1a961db10d69eb30e016205140";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."draw-lib" self."pict-lib" self."gui-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "slideshow-plugin" = self.lib.mkRacketDerivation rec {
  pname = "slideshow-plugin";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/slideshow-plugin.zip";
    sha1 = "46d43dab405e8db0dbefc3eb286077ef14b78a82";
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
    rev = "b50162981c77ce9d056dc49afb25c78f15731c7c";
    sha256 = "0qv2wswqnf1432jskb18s7anj25dz13ak35faa2sbnya0zplq2xs";
  };
  racketThinBuildInputs = [ self."base" self."gregor-lib" self."at-exp-lib" self."r6rs-lib" self."uuid" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/snip.zip";
    sha1 = "6223ae1149ccc4a04b1013f046dd8226e6e93e93";
  };
  racketThinBuildInputs = [ self."snip-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "snip-lib" = self.lib.mkRacketDerivation rec {
  pname = "snip-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/snip-lib.zip";
    sha1 = "0ae8663cc56ac9b4db41ab3d664122f6367e31e4";
  };
  racketThinBuildInputs = [ self."base" self."draw-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "social-contract" = self.lib.mkRacketDerivation rec {
  pname = "social-contract";
  src = fetchgit {
    name = "social-contract";
    url = "git://github.com/countvajhula/social-contract.git";
    rev = "aed8e30fca16fb7e640fedae5492d44064394095";
    sha256 = "14q6f62fidx2fld5dzqklsw2nnwrmyhrxnmwh7ckgq0l247l9yvv";
  };
  racketThinBuildInputs = [ self."base" self."collections-lib" self."scribble-lib" self."scribble-abbrevs" self."racket-doc" self."rackunit-lib" self."cover" self."cover-coveralls" self."sandbox-lib" ];
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
    rev = "75e1d1512613cbb1f4676c9329f0a1529d3b8cce";
    sha256 = "0dykjylr6s6gn4gyczfmknibxqpb3pzwswrf7gl571kvpcplghz8";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/source-syntax.zip";
    sha1 = "eeb62d0a4779186dee63a1d2633b1a794bf9b816";
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
    rev = "7bb2872fb7850f67a7db3c9e017dfc9b61bd612e";
    sha256 = "1gz9bzikg148i6lw9dyvj7xgwk09zy6gvxramd1csil8gjas8gal";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi.zip";
    sha1 = "00bbe62198694b24e7eace50e03fb4fc1cdd5796";
  };
  racketThinBuildInputs = [ self."srfi-lib" self."srfi-doc" self."srfi-doc-nonfree" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-doc" = self.lib.mkRacketDerivation rec {
  pname = "srfi-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi-doc.zip";
    sha1 = "25f4bf89334ecd49e226d3e11dcc3c845a9c1930";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."scheme-lib" self."base" self."scribble-lib" self."compatibility-lib" self."scheme-lib" self."base" self."scribble-lib" self."srfi-lib" self."compatibility-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-doc-nonfree" = self.lib.mkRacketDerivation rec {
  pname = "srfi-doc-nonfree";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi-doc-nonfree.zip";
    sha1 = "660dd5ab544a821d9c1e051daf88a625633c21df";
  };
  racketThinBuildInputs = [ self."mzscheme-doc" self."scheme-lib" self."base" self."scribble-lib" self."srfi-doc" self."racket-doc" self."r5rs-doc" self."r6rs-doc" self."compatibility-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-lib" = self.lib.mkRacketDerivation rec {
  pname = "srfi-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi-lib.zip";
    sha1 = "c1d7484f9d647dd04e8e28c3d56f78aca2bb4255";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi-lite-lib.zip";
    sha1 = "36a1a2fab32dbd4eb7f98dc0aa7f8e1a15a97e82";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "srfi-test" = self.lib.mkRacketDerivation rec {
  pname = "srfi-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/srfi-test.zip";
    sha1 = "2816c189b788dd0a0190b160c56c630c4bc15887";
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
  "stephens-favourite-quickscripts" = self.lib.mkRacketDerivation rec {
  pname = "stephens-favourite-quickscripts";
  src = fetchgit {
    name = "stephens-favourite-quickscripts";
    url = "git://github.com/spdegabrielle/stephens-favourite-quickscripts.git";
    rev = "f49ac0f8d869beddd03494c240839b384cd87cb1";
    sha256 = "0hqnfzr91rpjd7vi8m20ffq1gfxm6dlj5z41xfnk9pgx4ab0aq1n";
  };
  racketThinBuildInputs = [ self."data-lib" self."base" self."drracket" self."gui-lib" self."htdp-lib" self."markdown" self."net-lib" self."plot-gui-lib" self."plot-lib" self."quickscript" self."rackunit-lib" self."scribble-lib" self."search-list-box" self."syntax-color-lib" self."at-exp-lib" ];
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
  "stream-etc" = self.lib.mkRacketDerivation rec {
  pname = "stream-etc";
  src = fetchgit {
    name = "stream-etc";
    url = "git://github.com/camoy/stream-etc.git";
    rev = "53d469be0c4bdfb6a2407b4e24b74005aa4c0fcb";
    sha256 = "0cjzq071zk34ammpvhpir8a67yvy0allbbgjnsmy2lj6f8acc2hx";
  };
  racketThinBuildInputs = [ self."base" self."chk-lib" self."sandbox-lib" self."threading-doc" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "stream-values" = self.lib.mkRacketDerivation rec {
  pname = "stream-values";
  src = fetchgit {
    name = "stream-values";
    url = "git://github.com/sorawee/stream-values.git";
    rev = "a5e107f20b8794dc3b3bf6b9402ec1aa7af30c8b";
    sha256 = "06wx0dxlh9ad4x7hgms03hrxw2c91869rmxxxlax16wmskxj4xl3";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/string-constants.zip";
    sha1 = "6ff2106c365dacd55b75251434d6d0f1c32e867a";
  };
  racketThinBuildInputs = [ self."string-constants-lib" self."string-constants-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants-doc" = self.lib.mkRacketDerivation rec {
  pname = "string-constants-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/string-constants-doc.zip";
    sha1 = "c2e2461a7d12d96a22099ab75fe67874d11ddfd6";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."string-constants-lib" self."base" self."scribble-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants-lib" = self.lib.mkRacketDerivation rec {
  pname = "string-constants-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/string-constants-lib.zip";
    sha1 = "a919492373fbcb0102a9be689101465f0e2d2346";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "string-constants-lib-lgpl" = self.lib.mkRacketDerivation rec {
  pname = "string-constants-lib-lgpl";
  src = self.lib.extractPath {
    path = "string-constants-lib-lgpl";
    src = fetchgit {
    name = "string-constants-lib-lgpl";
    url = "git://github.com/racket/string-constants.git";
    rev = "992be713c785cbca2e436541de75597d98c15b4b";
    sha256 = "19mwrfkcykf6mk92cv0r4743qrc9crk5j1ssqrf0iy5b7bnmrbq9";
  };
  };
  racketThinBuildInputs = [ self."base" self."string-constants-lib" ];
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
    rev = "c961dbd9a5741895e838558bf19233fd4142e4d6";
    sha256 = "14jq1zvspj5dfxah2kbsf05li3w3f31hr804bl434m2qd7qyi0mb";
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
    rev = "a7b62bf51214031a969e0503143f4ee64c9f6fe2";
    sha256 = "15p9iyp29rxcc1w2n1jdn8cb3qfl2sgwzpicq2r6knm1wqlmvdc5";
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
    rev = "d35e84905fdbbef4309edca0a138cd77066be185";
    sha256 = "1f2zm0a25clm0p3p533jv87dwn8c5rs006wlfd8pbjgdzf2w92bk";
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
    rev = "990b0b589274a36a58e27197e771500c5898b5a2";
    sha256 = "1i6zpa8jhwmxnjxl6rhchgd4h3sn5g3p4xqlcfcmv9zmnwd426fl";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/swindle.zip";
    sha1 = "134ed42069be450267804c1c167d6ea0d065ec2e";
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
    rev = "d3b8570cf7287c4e06636e17634f0f5c39203d52";
    sha256 = "0xc8x3rcbx0lliqyfn0sgii6jdv1rwqzyvkls31pymjry4iq9vjp";
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
    rev = "165dfeb6c87f933f5eafcdecc84d79835210b40e";
    sha256 = "1hqlrdi4zbsw59mq9ab6bbfiydpp1d2w823zcvsjcn4llz31gklf";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/syntax-color.zip";
    sha1 = "a8dcb663ab65feaefbe49f29b1c073a655d81040";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."syntax-color-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-doc" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/syntax-color-doc.zip";
    sha1 = "242705f0fb2964948a99b04027d195af671e44aa";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."gui-lib" self."scribble-lib" self."syntax-color-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-lib" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/syntax-color-lib.zip";
    sha1 = "24ce21341a848e543a16d906229d4b69df00db0d";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."parser-tools-lib" self."option-contract-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-color-test" = self.lib.mkRacketDerivation rec {
  pname = "syntax-color-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/syntax-color-test.zip";
    sha1 = "430622528f7b0ef68c018a278f1bfed89656a085";
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
    rev = "d02c1847e606604e09d92bd5d2aec85d30e3dd48";
    sha256 = "1dipj235rv27ai708f84xazqxx7c1fn7ra8yjxqnqr0v22rw5kz8";
  };
  racketThinBuildInputs = [  ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "syntax-implicits" = self.lib.mkRacketDerivation rec {
  pname = "syntax-implicits";
  src = fetchgit {
    name = "syntax-implicits";
    url = "git://github.com/willghatch/racket-syntax-implicits.git";
    rev = "df1fb32a62348acbcc68e36a2a6a0fc6da4cea18";
    sha256 = "0s2xaq42a66qzdf0dsbinhbg5df9pcd4pdxqbm2wdh3imlqbcrhv";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
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
    rev = "d71edad70a023fb8e13b9841f2ec46117864f146";
    sha256 = "1d8g8m3pwc42g20mvvzmyvky2bvd49yx8kg41ndh5apzaydrf10v";
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
    rev = "2d06b1541888b94aa04a0d77aac9ebdd503ee90a";
    sha256 = "0hpa6ywwx3bavlpbwwvhrdrrzyjspaah02ky116imdxdmwb9hh23";
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
  "syrup" = self.lib.mkRacketDerivation rec {
  pname = "syrup";
  src = self.lib.extractPath {
    path = "impls%2Fracket%2Fsyrup";
    src = fetchgit {
    name = "syrup";
    url = "https://gitlab.com/spritely/syrup.git";
    rev = "80e57b55a61cf1deb34f051d0435730e7b2054e9";
    sha256 = "0v7j95w1k4mnafxn2rivp8pfh9x0s682h27p21kzi66hd0qbgak0";
  };
  };
  racketThinBuildInputs = [ self."base" ];
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
  "termconfig" = self.lib.mkRacketDerivation rec {
  pname = "termconfig";
  src = fetchgit {
    name = "termconfig";
    url = "git://github.com/dodgez/termconfig.git";
    rev = "620c2fee9491186fc5faf8a5d2b4c0eb67062657";
    sha256 = "1v366h4m6rvqx4shnfyk16nld0xfd99dsr9f0npknkw0s0hflil6";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "terminal-phase" = self.lib.mkRacketDerivation rec {
  pname = "terminal-phase";
  src = fetchgit {
    name = "terminal-phase";
    url = "https://gitlab.com/dustyweb/terminal-phase.git";
    rev = "ecf6f068c265de812d3decd003144ba4a2dd1e2b";
    sha256 = "18c2zzhr613c3vvy0zszwzp7xjqdxc8inyfvh22d5njqshbdm3gi";
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
  "tessellation" = self.lib.mkRacketDerivation rec {
  pname = "tessellation";
  src = fetchgit {
    name = "tessellation";
    url = "git://github.com/zkry/tessellation.git";
    rev = "6f881912eb35592f96539485e7bdd62bdc329528";
    sha256 = "1k4vr109h01lkls4468pgl0i61jxqpfkb996f59frdl96im8s8rx";
  };
  racketThinBuildInputs = [ self."base" self."metapict" self."scribble-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/testing-util-lib.zip";
    sha1 = "6ad98392863d6f61974ef502fc0c6bf4241f492f";
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
    rev = "bbf9dc58b8b1606f574ebf1a466eeef278689a68";
    sha256 = "0i58y2ig6220smsch27la1kapwk36rk22dr4a101ikcbs4ndzxsw";
  };
  racketThinBuildInputs = [ self."base" self."htdp-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "tex-table" = self.lib.mkRacketDerivation rec {
  pname = "tex-table";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/tex-table.zip";
    sha1 = "faa0ecef5a893596bb240eb314caf0cd161ac71f";
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
    rev = "5cbfa2012b3ec3209e17ba00e6753b8eea2c237b";
    sha256 = "0l1ywws3vvjn6wbvhw4s9hfsj0m21c2ii14i7q1kxa4247fd4z3b";
  };
  racketThinBuildInputs = [ self."base" self."sandbox-lib" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "the-unicoder" = self.lib.mkRacketDerivation rec {
  pname = "the-unicoder";
  src = fetchgit {
    name = "the-unicoder";
    url = "git://github.com/willghatch/the-unicoder.git";
    rev = "c95473838a9f0893b1d39742b087203f702a540c";
    sha256 = "0m7nqfc17zn0hhvy893jblsgndv87cp895sibmz5v4zilan11ri4";
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
  "thread-with-id" = self.lib.mkRacketDerivation rec {
  pname = "thread-with-id";
  src = fetchgit {
    name = "thread-with-id";
    url = "git://github.com/dstorrs/thread-with-id.git";
    rev = "0b5908a810b710bae7a8e0bc89f6468c81d12f92";
    sha256 = "0sy404g7a7cywdqmmrclkwjw64jm7w3hd15lv44lwbjjw4csl4xh";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."sandbox-lib" self."scribble-lib" ];
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
    rev = "6c3eabdf5b4365ebc39c0eba4a7141082d3e3d5d";
    sha256 = "1agky77b82bpn5dngmx2avbjxzvyg99mwdn5pdv6qkd9z0m050qd";
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
    rev = "218e8862718327696b2a7cd2e1ae82800a653306";
    sha256 = "1ihakm2g3kh43c2fjwj50xr46vwhz9lb6adjwj2aqc73g93r6cvn";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-map-lib" self."scribble-lib" self."racket-doc" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "trace" = self.lib.mkRacketDerivation rec {
  pname = "trace";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/trace.zip";
    sha1 = "a000c4e2284f4c45eeb43d1d246ab1cc0e165387";
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
  "trie" = self.lib.mkRacketDerivation rec {
  pname = "trie";
  src = fetchgit {
    name = "trie";
    url = "git://github.com/dstorrs/racket-trie.git";
    rev = "da9564e8187ace2a4a891c979ef1e7f15a3d306e";
    sha256 = "1x2zp2n9yxhmc501a223g3w14lq5b4rckjav9a57k6czafngxjfc";
  };
  racketThinBuildInputs = [ self."base" self."handy" self."struct-plus-plus" self."scribble-lib" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."handy" ];
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
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
    rev = "05ec31f2e1fe0ddd653211e041e06c6c8071ffa6";
    sha256 = "1a98kj7z01jn7r60xlv4zcyzpksayvfxp38q3jgwvjsi50r2i017";
  };
  };
  racketThinBuildInputs = [ self."base" self."turnstile-lib" self."turnstile-example" self."rackunit-macrotypes-lib" ];
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
    rev = "435c6e6f36fd39065ae9d8a00285fda0e4e41fa1";
    sha256 = "0nc71v5i6c02miy6wbkmfda74ppmlfa1532dhxh72986rs4xwsjg";
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
    rev = "b182b9422083bf8adee71d6543f78372ad801ede";
    sha256 = "0m3jzmcklyggnkyfm507xias7jwbd69acgfvk3ar3yizbhqzvg5f";
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."scribble-lib" self."typed-racket-lib" self."typed-racket-more" self."hyper-literate" self."auto-syntax-e" self."debug-scopes" self."version-case" self."scribble-lib" self."racket-doc" self."typed-racket-more" self."typed-racket-doc" self."scribble-enhanced" self."mutable-match-lambda" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-compose" = self.lib.mkRacketDerivation rec {
  pname = "typed-compose";
  src = fetchgit {
    name = "typed-compose";
    url = "https://git.marvid.fr/scolobb/typed-compose.git";
    rev = "69de45761367a99ee919ba84c33abddb06419e87";
    sha256 = "06rxyqm3rrl65wv820j60rjjcfzy7v61wjji00y3jr5bf15c2gkk";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."base" self."racket-doc" self."rackunit-typed" self."sandbox-lib" self."scribble-lib" ];
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
    rev = "7a70650b6f8e1222fe1e4ebd2fb6b9b2489301e2";
    sha256 = "10hnjsg89nsfhk86md2cz7qqqlaim1im9s7v4z58gzq1lkig6igf";
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
    rev = "7a70650b6f8e1222fe1e4ebd2fb6b9b2489301e2";
    sha256 = "10hnjsg89nsfhk86md2cz7qqqlaim1im9s7v4z58gzq1lkig6igf";
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
    rev = "7a70650b6f8e1222fe1e4ebd2fb6b9b2489301e2";
    sha256 = "10hnjsg89nsfhk86md2cz7qqqlaim1im9s7v4z58gzq1lkig6igf";
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
    rev = "7a70650b6f8e1222fe1e4ebd2fb6b9b2489301e2";
    sha256 = "10hnjsg89nsfhk86md2cz7qqqlaim1im9s7v4z58gzq1lkig6igf";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."typed-racket-lib" self."typed-racket-more" self."typed-map-lib" self."aful" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-minikanren" = self.lib.mkRacketDerivation rec {
  pname = "typed-minikanren";
  src = fetchgit {
    name = "typed-minikanren";
    url = "git://github.com/dalev/minikanren-typed-racket.git";
    rev = "9cf4deb8a45ab8b0cf2d09b87c6774d58e465927";
    sha256 = "0an7vfksp9sbh1db4s1yn6pxmb4xyydkk0nmcdfr822snghyql90";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-otp-lib" = self.lib.mkRacketDerivation rec {
  pname = "typed-otp-lib";
  src = self.lib.extractPath {
    path = "typed-otp-lib";
    src = fetchgit {
    name = "typed-otp-lib";
    url = "git://github.com/yilinwei/otp.git";
    rev = "0757167eac914c45a756c090c4bdf5410080c145";
    sha256 = "00n7fql77x03ax17wmxzjc2f4xs86xllsxxsqww17m713vh8mam9";
  };
  };
  racketThinBuildInputs = [ self."base" self."crypto-lib" self."otp-lib" self."typed-racket-lib" self."rackunit-typed" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket.zip";
    sha1 = "74165080722ebcd70123a27d602342732d3f2520";
  };
  racketThinBuildInputs = [ self."typed-racket-lib" self."typed-racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-compatibility" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-compatibility";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket-compatibility.zip";
    sha1 = "f20a587cb6e2c99cf5210be0f6d2bc59c14f1578";
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
    rev = "dc955052081b18a164552c4e7db75ac392a92402";
    sha256 = "18kra3fs5hyangjrf5vb088r96in87jhzbfi9llq9315jxv9ysny";
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
    rev = "dc955052081b18a164552c4e7db75ac392a92402";
    sha256 = "18kra3fs5hyangjrf5vb088r96in87jhzbfi9llq9315jxv9ysny";
  };
  };
  racketThinBuildInputs = [ self."base" self."typed-racket-lib" self."syntax-classes-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-doc" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket-doc.zip";
    sha1 = "3518029e9848c4668398ee2d9e028d18eb0dc495";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket-lib.zip";
    sha1 = "d9133563d22a3b2135aa8aee3b43560328447a5f";
  };
  racketThinBuildInputs = [ self."base" self."source-syntax" self."pconvert-lib" self."compatibility-lib" self."string-constants-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "typed-racket-more" = self.lib.mkRacketDerivation rec {
  pname = "typed-racket-more";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket-more.zip";
    sha1 = "395a3b78f394176f071b21f54478cd2816952ab2";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/typed-racket-test.zip";
    sha1 = "59ce74b497b86571744784d16775710650dcad62";
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
    rev = "5bcf55322b3a97ecfb0233ed77f282507eb2f6ad";
    sha256 = "1l5m376mnqjbhpvylnwlyigisjdddimyyhafqx7bcmbb1c7y6z88";
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
    rev = "5512b7f4c9dff6b2be445435b86babfc9b189fc8";
    sha256 = "1sy1dz2z478kcxfcc9z0lzy0malmdxqiwqsmsxs8904ilb45lzrf";
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
    rev = "31fb17fb7c8aaa96c49dcd1ca9094d0dffa775c8";
    sha256 = "0whx3m1vnqq6c38rdx90858nkjzdq48d5ciz3nybm0f8kmp91bbs";
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
    rev = "58420f53c37e0bee451daa3dc5e2d72f7fc4d967";
    sha256 = "0h3ha4qxh8jhxg1phyqnbz51xznzgjgfxaaxxxj1wp2kdy3dn7ff";
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
  "unb-cs2613" = self.lib.mkRacketDerivation rec {
  pname = "unb-cs2613";
  src = fetchgit {
    name = "unb-cs2613";
    url = "https://pivot.cs.unb.ca/git/unb-cs2613.git";
    rev = "67576e2029d4865143c458b26fbc9da78c066a66";
    sha256 = "0q5kxkwyq7kllkskkssv14q7pdy5wiyjy0pxkkcbyy81kgaafwnr";
  };
  racketThinBuildInputs = [ self."base" self."drracket" self."drracket-plugin-lib" self."frog" self."explorer" self."date" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unb-cs4613" = self.lib.mkRacketDerivation rec {
  pname = "unb-cs4613";
  src = fetchgit {
    name = "unb-cs4613";
    url = "https://pivot.cs.unb.ca/git/unb-cs4613.git";
    rev = "2822b8c4d4864c79181608ae0e73d9f04c24f43c";
    sha256 = "117m2fc5dajahdzdllc332ngqv5pn91i5s4lc63qr06aaamqxqpq";
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
    rev = "a0c50918dac6cf5df7d0789d13dac9759eab5606";
    sha256 = "0h8lk9181ffyi07hvh2bcpl74iwl84950icxx3f1aymhxj7gpknf";
  };
  racketThinBuildInputs = [ self."base" self."dynext-lib" self."racket-doc" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/unix-socket.zip";
    sha1 = "c5c0da19f7126f3f4b1ccbdf12cd497aa4c22531";
  };
  racketThinBuildInputs = [ self."unix-socket-lib" self."unix-socket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-doc" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/unix-socket-doc.zip";
    sha1 = "ed51ed4f68ad1cf8e149e04aa0c6d10f09efabfa";
  };
  racketThinBuildInputs = [ self."base" self."unix-socket-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-lib" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/unix-socket-lib.zip";
    sha1 = "d0873a69508940aa017c7a6b0daf74c6971bd866";
  };
  racketThinBuildInputs = [ self."base" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "unix-socket-test" = self.lib.mkRacketDerivation rec {
  pname = "unix-socket-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/unix-socket-test.zip";
    sha1 = "02ded14fde965c4af71d1d0a6c8a7b4f0a22496b";
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
    rev = "086622e2306e72731016c7108aca3328e5082aee";
    sha256 = "0iw156i9axd3nx8xpdy173cfmprqw5lp6zkjacickhvw1gc1shpz";
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
  "uwaterloo-racket-tools" = self.lib.mkRacketDerivation rec {
  pname = "uwaterloo-racket-tools";
  src = self.lib.extractPath {
    path = "uwaterloo-racket-tools";
    src = fetchgit {
    name = "uwaterloo-racket-tools";
    url = "git://github.com/djh-uwaterloo/uwaterloo-racket.git";
    rev = "24f1c0034ea24180c4d501eb51efd96f5f349215";
    sha256 = "0s58a0bwmrc5n8bzw1k59vlf7js82jr538iq73n4c9xlrm4kcx2q";
  };
  };
  racketThinBuildInputs = [ self."base" self."htdp-trace" self."graphic-block" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "value-evt" = self.lib.mkRacketDerivation rec {
  pname = "value-evt";
  src = fetchgit {
    name = "value-evt";
    url = "git://github.com/dstorrs/value-evt.git";
    rev = "10c3b0cc46f7fface88d2609c6de29ed5cea5767";
    sha256 = "02jk25vb51i5rbq0naag2bx8g8qlvlb73xd0y39d9lbg7nwkwrim";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."sandbox-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "values" = self.lib.mkRacketDerivation rec {
  pname = "values";
  src = fetchgit {
    name = "values";
    url = "git://github.com/dedbox/racket-values.git";
    rev = "beec5757368e9bf64a42c7b0f5e5a0fa49f622c5";
    sha256 = "0rw4d3iq7qahlp5vlpmff4pm0zr9vp0qay3kx8jqja10k183s0ll";
  };
  racketThinBuildInputs = [ self."base" self."racket-doc" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" ];
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
  "version-string-with-git-hash" = self.lib.mkRacketDerivation rec {
  pname = "version-string-with-git-hash";
  src = fetchgit {
    name = "version-string-with-git-hash";
    url = "https://gitlab.flux.utah.edu/xsmith/version-string-with-git-hash.git";
    rev = "64bc518ac25e5810fa155a8d8ebbfaa4d008e8bc";
    sha256 = "1zn6gwd2pwqx32i82aypd9wg84kkpy5a3566fzgca0190x0rh38s";
  };
  racketThinBuildInputs = [ self."base" self."scribble-lib" self."racket-doc" ];
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
    rev = "4f743b4b2933173ee4f141e5ae94739895c54b67";
    sha256 = "0vxs0cx534gsxv30mk96sgka7f6v8q34fg7s34j948qad2dgl53p";
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
    rev = "54257dcc11402de0fefac55dee6a14a2b4263ad4";
    sha256 = "0jbbdqfmwfv2pf5gahr9c3kdkk7wxnya37cm8n0jx4hi4gkg4cc6";
  };
  racketThinBuildInputs = [ self."graphics+w3s" self."base" self."typed-racket-lib" self."typed-racket-more" self."scribble-lib" self."racket-doc" self."typed-racket-doc" self."digimon" ];
  circularBuildInputs = [ "graphics" "w3s" ];
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
  "wasm-lib" = self.lib.mkRacketDerivation rec {
  pname = "wasm-lib";
  src = self.lib.extractPath {
    path = "wasm-lib";
    src = fetchgit {
    name = "wasm-lib";
    url = "git://github.com/Bogdanp/racket-wasm.git";
    rev = "9d84041f8de1ad4d9c6ac6e80c381ee525a1d30a";
    sha256 = "1ygi8qj8a5sds1xg6pf0s8dipdqns4s8vdybfcvl7sfxikkxv1k0";
  };
  };
  racketThinBuildInputs = [ self."base" self."data-lib" self."threading-lib" ];
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
  "wavenet" = self.lib.mkRacketDerivation rec {
  pname = "wavenet";
  src = fetchgit {
    name = "wavenet";
    url = "git://github.com/otherjoel/wavenet-api.git";
    rev = "71c9fd2f66078a808f1dc837146a34ee4a2dfd6c";
    sha256 = "10znlas02yqmxwhyl5jkjw1dmshigrvbh6c9c93d02bzi9l6w6jh";
  };
  racketThinBuildInputs = [ self."base" self."hash-view-lib" self."http-easy" self."gui-doc" self."gui-lib" self."hash-view" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/web-server.zip";
    sha1 = "2ea50eb0a4e0de260214623ffe99260bf87acb96";
  };
  racketThinBuildInputs = [ self."web-server-lib" self."web-server-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-doc" = self.lib.mkRacketDerivation rec {
  pname = "web-server-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/web-server-doc.zip";
    sha1 = "691c85a77c041791fc543586cdb08f68f915da93";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."compatibility-lib" self."db-lib" self."net-lib" self."net-cookies-lib" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."web-server-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-lib" = self.lib.mkRacketDerivation rec {
  pname = "web-server-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/web-server-lib.zip";
    sha1 = "1970bd36ccb697c6b377cad0777bb38457bceca1";
  };
  racketThinBuildInputs = [ self."srfi-lite-lib" self."base" self."net-lib" self."net-cookies-lib" self."compatibility-lib" self."scribble-text-lib" self."parser-tools-lib" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "web-server-test" = self.lib.mkRacketDerivation rec {
  pname = "web-server-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/web-server-test.zip";
    sha1 = "911de7388d99654f36a944fa4179156d052f6960";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/wxme.zip";
    sha1 = "e6121a8db562342a10109f1b281d6532f31d9566";
  };
  racketThinBuildInputs = [ self."wxme-lib" self."gui-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wxme-lib" = self.lib.mkRacketDerivation rec {
  pname = "wxme-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/wxme-lib.zip";
    sha1 = "fba7cba8163e32c08e471c8bcc73b0bdc4ee759c";
  };
  racketThinBuildInputs = [ self."scheme-lib" self."base" self."compatibility-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wxme-test" = self.lib.mkRacketDerivation rec {
  pname = "wxme-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/wxme-test.zip";
    sha1 = "a8150f7bb2169fb9a28dcae0e721ffa1673d7659";
  };
  racketThinBuildInputs = [ self."rackunit" self."wxme-lib" self."base" self."gui-lib" self."snip-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "wy-posn-util" = self.lib.mkRacketDerivation rec {
  pname = "wy-posn-util";
  src = fetchgit {
    name = "wy-posn-util";
    url = "git://github.com/maueroats/wy-posn-util.git";
    rev = "2665d883bba8f1f720e469b8f971e385be05eb05";
    sha256 = "0ys3ydcazw8q44dc8yx8ihwh148vwaydswjgksdf1gd52d7ja44h";
  };
  racketThinBuildInputs = [ self."htdp-lib" self."rackunit-lib" self."base" self."scribble-lib" self."racket-doc" self."rackunit-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "x11" = self.lib.mkRacketDerivation rec {
  pname = "x11";
  src = fetchgit {
    name = "x11";
    url = "git://github.com/kazzmir/x11-racket.git";
    rev = "97c4a75872cfd2882c8895bba88b87a4ad12be0e";
    sha256 = "01j9gbk2smps5q74r29gnk6p6caf43xsi1asn1ycxr9n2s9z2w2h";
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
    rev = "b8a4e9998428f4f0b1d083d74d9730e8369f0110";
    sha256 = "0wwh25gx0rnpql6cw14j5sg1xgckahm2qglj8n562nwwa9nq0hfb";
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
    rev = "b8a4e9998428f4f0b1d083d74d9730e8369f0110";
    sha256 = "0wwh25gx0rnpql6cw14j5sg1xgckahm2qglj8n562nwwa9nq0hfb";
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
    rev = "b8a4e9998428f4f0b1d083d74d9730e8369f0110";
    sha256 = "0wwh25gx0rnpql6cw14j5sg1xgckahm2qglj8n562nwwa9nq0hfb";
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
    rev = "e578e752c96a5fb6e16a5004651372853851093f";
    sha256 = "0qdgfvrvk2faq806a34gpn4f66kxb7540afqydjlsgbfm5gff8jf";
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
  "xiden" = self.lib.mkRacketDerivation rec {
  pname = "xiden";
  src = fetchgit {
    name = "xiden";
    url = "git://github.com/zyrolasting/xiden.git";
    rev = "1f9e6d61ef991d75e606275fdf8873310fa67c8b";
    sha256 = "0kc58vfydfjbkp1c3br8l7yqppms2hj23qlpf8rrzxi4q4ml6vd4";
  };
  racketThinBuildInputs = [ self."base" self."compatibility-lib" self."db-lib" self."rackunit-lib" self."sandbox-lib" self."scribble-lib" self."net-doc" self."racket-doc" ];
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
    rev = "e82c02f99186b062df86a92dc63a954861e36064";
    sha256 = "0558cgwqyj34b3ylc92gyjn2x8n3r1zmr933fci51mxp9j5z3lka";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/xrepl.zip";
    sha1 = "eab37bec672b58be15cf197e4501ce003b9c0362";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."xrepl-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-doc" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-doc";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/xrepl-doc.zip";
    sha1 = "467379606cd0cdc66d5b20009bb1a496bcab2542";
  };
  racketThinBuildInputs = [ self."compatibility+compatibility-doc+data-doc+db-doc+distributed-p..." self."base" self."sandbox-lib" self."scribble-lib" self."macro-debugger-text-lib" self."profile-lib" self."readline-lib" self."xrepl-lib" ];
  circularBuildInputs = [ "racket-doc" "readline" "draw" "syntax-color" "parser-tools-doc" "compatibility" "pict" "future-visualizer" "distributed-places-doc" "distributed-places" "trace" "planet-doc" "quickscript" "drracket-tool-doc" "drracket" "gui" "xrepl" "typed-racket-doc" "slideshow-doc" "pict-doc" "draw-doc" "syntax-color-doc" "string-constants-doc" "readline-doc" "macro-debugger" "errortrace-doc" "profile-doc" "xrepl-doc" "gui-doc" "scribble-doc" "net-cookies-doc" "net-doc" "compatibility-doc" "rackunit-doc" "web-server-doc" "db-doc" "mzscheme-doc" "r5rs-doc" "r6rs-doc" "srfi-doc" "plot-doc" "math-doc" "data-doc" ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-lib" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-lib";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/xrepl-lib.zip";
    sha1 = "cda5c3dbae016a71ea13a603cbba0445ebd4103a";
  };
  racketThinBuildInputs = [ self."base" self."readline-lib" self."scribble-text-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xrepl-test" = self.lib.mkRacketDerivation rec {
  pname = "xrepl-test";
  src = fetchurl {
    url = "https://download.racket-lang.org/releases/7.8/pkgs/xrepl-test.zip";
    sha1 = "ec735b1978194eac75fa74ca3a6f523a57a9f28f";
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
    rev = "b5401707e5e225ac8f57e15843ffb8459a382235";
    sha256 = "0k1hxnkyhiwr75zfyadrclvx4kbfbz5br8i5mx2wkld7nr1qhxdl";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."pprint" self."racr" self."clotho" self."math-lib" self."unix-socket-lib" self."memoize" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "xsmith-examples" = self.lib.mkRacketDerivation rec {
  pname = "xsmith-examples";
  src = self.lib.extractPath {
    path = "xsmith-examples";
    src = fetchgit {
    name = "xsmith-examples";
    url = "https://gitlab.flux.utah.edu/xsmith/xsmith.git";
    rev = "b5401707e5e225ac8f57e15843ffb8459a382235";
    sha256 = "0k1hxnkyhiwr75zfyadrclvx4kbfbz5br8i5mx2wkld7nr1qhxdl";
  };
  };
  racketThinBuildInputs = [ self."base" self."rackunit-lib" self."at-exp-lib" self."pprint" self."racr" self."xsmith" self."rosette" self."clotho" self."math-lib" self."scribble-lib" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
  "yaml" = self.lib.mkRacketDerivation rec {
  pname = "yaml";
  src = fetchgit {
    name = "yaml";
    url = "git://github.com/esilkensen/yaml.git";
    rev = "b60a1e4a01979ed447799b07e7f8dd5ff17019f0";
    sha256 = "01r8lhz8b31fd4m5pr5ifmls1rk0rs7yy3mcga3k5wfzkvjhc6pg";
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
  "zeromq-guide-examples" = self.lib.mkRacketDerivation rec {
  pname = "zeromq-guide-examples";
  src = self.lib.extractPath {
    path = "zeromq-guide-examples";
    src = fetchgit {
    name = "zeromq-guide-examples";
    url = "git://github.com/aymanosman/racket-packages.git";
    rev = "b938f6e33d04cfd62f9a328543d3943a0f3f53a0";
    sha256 = "1hag69ka39bdhbrjxsl0kgwrf2hhi7k4sr42q4pcm378agyg28hn";
  };
  };
  racketThinBuildInputs = [ self."base" self."zeromq-r-lib" ];
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
    rev = "d45ee2bbc64582b22055eee20d0ef777d519a3b4";
    sha256 = "047vss5q557h6600n91358gqwf7v1mw3bs3wjsmkna7llrzzyl6k";
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
    rev = "d45ee2bbc64582b22055eee20d0ef777d519a3b4";
    sha256 = "047vss5q557h6600n91358gqwf7v1mw3bs3wjsmkna7llrzzyl6k";
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
    url = "https://download.racket-lang.org/releases/7.8/pkgs/zo-lib.zip";
    sha1 = "bd643733b40b9c4169653bfbd1f8fe5e7004dce4";
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
    rev = "97e3365d8b4343d7ec23df3fa9640fd865d66841";
    sha256 = "0i4gjc3ikachjs0h396bgikzzxlkm2nixylzpb5gjyy6qg8l8728";
  };
  racketThinBuildInputs = [ self."base" self."html-parsing" self."sxml" self."rackunit-lib" self."scribble-lib" self."racket-doc" ];
  circularBuildInputs = [  ];
  reverseCircularBuildInputs = [  ];
  };
}); in
racket-packages
