{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.eve-edge;
in {
  imports = [
    ./zedagent.nix
    ./nim.nix
    ./onboarding.nix
    ./controller-config.nix
    ./device-identity.nix
    ./controller-trust.nix
    ./soft-serial.nix
  ];

  options.services.eve-edge.enable =
    lib.mkEnableOption "EVE-like edge node";

  config = lib.mkIf cfg.enable {
    environment.etc."eve-edge/status".text = "module-enabled\n";

    systemd.services.eve-edge-demo = {
      description = "EVE Edge Module Demo";

      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/echo eve-edge-module-started";
      };
    };
  };
}
