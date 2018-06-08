{ pkgs ? import ./nixpkgs.nix { }
, stdenvNoCC ? pkgs.stdenvNoCC
, racket ? pkgs.callPackage ./racket-minimal.nix {}
, cacert ? pkgs.cacert
, exclusions ? ./catalog-exclusions.rktd
, overrides ? ./catalog-overrides.rktd
}:

let attrs = rec {
  release-catalog = stdenvNoCC.mkDerivation {
    name = "release-catalog";
    src = ./nix;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      $racket/bin/racket -N dump-catalogs ./dump-catalogs.rkt https://download.racket-lang.org/releases/6.12/catalog/ > $out
    '';
    inherit racket;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1p8f4yrnv9ny135a41brxh7k740aiz6m41l67bz8ap1rlq2x7pgm";
  };
  live-catalog = stdenvNoCC.mkDerivation {
    name = "live-catalog";
    src = ./nix;
    buildInputs = [ racket ];
    phases = "unpackPhase installPhase";
    installPhase = ''
      $racket/bin/racket -N dump-catalogs ./dump-catalogs.rkt \
        https://web.archive.org/web/20180331093137if_/https://pkgs.racket-lang.org/ > $out
    '';
    inherit racket;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1snqa4wd5j14zmd4slqhcf6bmvqfd91mivil5294gjyxl1rirg7r";
  };
  mergedUnfilteredCatalog = pkgs.runCommand "merged-unfiltered-catalog.rktd" {
    inherit overrides racket;
    buildInputs = [ racket ];
  } ''
    $racket/bin/racket -N export-catalog ${./nix/racket2nix.rkt} \
      --export-catalog --no-process-catalog --catalog $overrides \
      --catalog ${release-catalog} --catalog ${live-catalog} > $out
  '';
  merged-catalog = pkgs.runCommand "merged-catalog.rktd" {
    inherit exclusions mergedUnfilteredCatalog racket;
    buildInputs = [ racket ];
    filterCatalog = builtins.toFile "filter-catalog.scm" ''
      #lang racket
      (command-line
        #:program "filter-catalog"
        #:args (exclusions-file)
          (let ([exclusions (call-with-input-file* exclusions-file read)])
            (for/fold ([h (make-immutable-hash)]) ([(k v) (in-hash (read))])
              (if (member k exclusions)
                  h
                  (hash-set h k v)))))
    '';
  } ''
    $racket/bin/racket -N filter-catalog $filterCatalog $exclusions \
      < $mergedUnfilteredCatalog > $out
  '';
  pretty-merged-catalog = stdenvNoCC.mkDerivation {
    name = "pretty-merged-catalog.rktd";
    buildInputs = [ racket ];
    phases = "installPhase";
    installPhase = ''
      ${racket}/bin/racket -e '(pretty-print (read))' < ${merged-catalog} > $out
    '';
  };
};
in
attrs.merged-catalog // attrs
