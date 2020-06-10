self: super: {
  "nix" = self.lib.mkRacketDerivation rec {
  pname = "nix";
  src = ./nix;
  racketThinBuildInputs = [ self."base" self."graph-lib" self."rackunit-lib" ];
  };

}
