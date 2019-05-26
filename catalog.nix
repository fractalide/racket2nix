{ pkgs ? import ./pkgs {}
, callPackage ? pkgs.callPackage
, exclusions ? ./catalog-exclusions.rktd
, overrides ? ./catalog-overrides.rktd
}:

callPackage ({cacert, fetchurl, racket, runCommand}: let
attrs = rec {
  releaseCatalog = with (builtins.fromJSON (builtins.readFile ./release-catalog.json));
  runCommand "release-catalog" {
    src = ./nix;
    buildInputs = [ cacert racket ];
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    inherit outputHash;
  } ''
    cd $src
    racket -N dump-catalogs ./dump-catalogs.rkt ${url} > $out
  '';
  liveCatalog = fetchurl (builtins.fromJSON (builtins.readFile ./live-catalog.json));
  mergedUnfilteredCatalog = runCommand "merged-unfiltered-catalog.rktd" {
    src = ./nix;
    inherit liveCatalog overrides releaseCatalog;
    buildInputs = [ cacert racket ];
  } ''
    cd $src
    racket -N export-catalog ./racket2nix.rkt \
      --export-catalog --no-process-catalog --catalog $overrides \
      --catalog $releaseCatalog --catalog $liveCatalog > $out
  '';
  merged-catalog = runCommand "merged-catalog.rktd" {
    inherit exclusions mergedUnfilteredCatalog racket;
    buildInputs = [ cacert racket ];
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
    buildInputs = [ cacert racket ];
  } ''
    racket -e '(pretty-write (read))' < ${merged-catalog} > $out
  '';
};
in
attrs.merged-catalog // attrs // { inherit attrs; }) {}
