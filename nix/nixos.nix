# NixOS module: programs.wakeful, for systems without Home Manager.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.wakeful;
  unit = import ./service.nix { inherit (cfg) package; };
in
{
  options.programs.wakeful = {
    enable = lib.mkEnableOption "Wakeful, a tray app that keeps the session awake for a set time";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "wakeful.packages.\${system}.default";
      description = "The wakeful package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    systemd.user.services.wakeful = {
      description = unit.Unit.Description;
      partOf = unit.Unit.PartOf;
      after = unit.Unit.After;
      wantedBy = unit.Install.WantedBy;
      serviceConfig = unit.Service;
    };
  };
}
