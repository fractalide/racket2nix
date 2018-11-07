{ pkgs ? import ./pkgs { }
, exclusions ? ./catalog-exclusions.rktd
, overrides ? ./catalog-overrides.rktd
}:

let
inherit (pkgs) cacert racket runCommand;
attrs = rec {
  releaseCatalog = with (builtins.fromJSON (builtins.readFile ./release-catalog.json));
  runCommand "release-catalog" {
    src = ./nix;
    buildInputs = [ racket ];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    inherit outputHash;
  } ''
    cd $src
    racket -N dump-catalogs ./dump-catalogs.rkt ${url} > $out
  '';
  liveCatalog = runCommand "live-catalog" {
    src = ./nix;
    buildInputs = [ racket ];
    inherit racket;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "0h1s04smfxhywddkwklibnlcpaffp60jw6xpblmx7y73d71g9k7x";
    url = "https://web.archive.org/web/20181106081240if_/https://pkgs.racket-lang.org/";
  } ''
    cd $src
    racket > $out -N dump-catalogs ./dump-catalogs.rkt $url
  '';
  mergedUnfilteredCatalog = runCommand "merged-unfiltered-catalog.rktd" {
    src = ./nix;
    inherit liveCatalog overrides releaseCatalog;
    buildInputs = [ racket ];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
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
    racket -e '(pretty-write (read))' < ${merged-catalog} > $out
  '';
};
in
attrs.merged-catalog // attrs // { inherit attrs; }
