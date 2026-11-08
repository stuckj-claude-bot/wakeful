# Home Manager module: services.wakeful.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wakeful;
in
{
  options.services.wakeful = {
    enable = lib.mkEnableOption "Wakeful, a tray app that keeps the session awake for a set time";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "wakeful.packages.\${system}.default";
      description = "The wakeful package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    systemd.user.services.wakeful = import ./service.nix { inherit (cfg) package; };
  };
}
