import <nix/fetchurl.nix>
(builtins.fromJSON (builtins.readFile ./default.json))
