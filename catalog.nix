{ pkgs ? import ./pkgs { }
, exclusions ? ./catalog-exclusions.rktd
, overrides ? ./catalog-overrides.rktd
}:

let
inherit (pkgs) cacert racket runCommand;
attrs = rec {
  releaseCatalog = runCommand "release-catalog" {
    src = ./nix;
    buildInputs = [ racket ];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1p8f4yrnv9ny135a41brxh7k740aiz6m41l67bz8ap1rlq2x7pgm";
  } ''
    cd $src
    racket -N dump-catalogs ./dump-catalogs.rkt \
      https://download.racket-lang.org/releases/6.12/catalog/ > $out
  '';
  liveCatalog = runCommand "live-catalog" {
    src = ./nix;
    buildInputs = [ racket ];
    inherit racket;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "1snqa4wd5j14zmd4slqhcf6bmvqfd91mivil5294gjyxl1rirg7r";
  } ''
    cd $src
    racket -N dump-catalogs ./dump-catalogs.rkt \
      https://web.archive.org/web/20180331093137if_/https://pkgs.racket-lang.org/ > $out
  '';
  mergedUnfilteredCatalog = runCommand "merged-unfiltered-catalog.rktd" {
    src = ./nix;
    inherit liveCatalog overrides releaseCatalog;
    buildInputs = [ racket ];
  } ''
    cd $src
    racket -N export-catalog ./racket2nix.rkt \
      --export-catalog --no-process-catalog --catalog $overrides \
      --catalog $releaseCatalog --catalog $liveCatalog > $out
  '';
  merged-catalog = runCommand "merged-catalog.rktd" {
    inherit exclusions mergedUnfilteredCatalog racket;
    buildInputs = [ racket ];
    filterCatalog = builtins.toFile "filter-catalog.scm" ''
      #lang racket
      (command-line
        #:program "filter-catalog"
        #:args (exclusions-file)
          (write (let ([exclusions (call-with-input-file* exclusions-file read)])
            (for/fold ([h (make-immutable-hash)]) ([(k v) (in-hash (read))])
              (if (member k exclusions)
                  h
                  (hash-set h k v))))))
    '';
  } ''
    racket -N filter-catalog $filterCatalog $exclusions \
      < $mergedUnfilteredCatalog > $out
  '';
  pretty-merged-catalog = runCommand "pretty-merged-catalog.rktd" {
    buildInputs = [ racket ];
  } ''
    racket -e '(pretty-print (read))' < ${merged-catalog} > $out
  '';
};
in
attrs.merged-catalog // attrs // { inherit attrs; }
