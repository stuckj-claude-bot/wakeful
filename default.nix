{
  pkgs ? import <nixpkgs> { },
}:

pkgs.callPackage ./nix/package.nix {
  # Version is updated by the release workflow before tagging
  version = "0.1.0";
  src = ./.;
}
