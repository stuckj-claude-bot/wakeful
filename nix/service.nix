# The user service both modules install, in Home Manager's unit syntax.
#
# Restart=on-failure brings the tray back after a crash, which is also when an
# unrestored lid setting is put back. With this service, leave the tray's own
# "Start at login" off: a second copy would exit straight away, but there is no
# reason to start one.
{ package }:
{
  Unit = {
    Description = "Wakeful: keep the session awake for a set time";
    PartOf = [ "graphical-session.target" ];
    After = [ "graphical-session.target" ];
  };
  Service = {
    ExecStart = "${package}/bin/wakeful";
    Restart = "on-failure";
    RestartSec = 2;
  };
  Install.WantedBy = [ "graphical-session.target" ];
}
