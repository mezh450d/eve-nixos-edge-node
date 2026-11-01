{ config, lib, pkgs, ... }:

let
  cfg = config.services.eve-edge;
in
{
  options.services.eve-edge.controllerAddress =
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "controller.example.com:8080";

      description =
        "Address of the EVE controller (host:port)";
    };

  config = lib.mkIf
    (cfg.enable && cfg.controllerAddress != null) {

    systemd.tmpfiles.rules = [
      "d /config 0755 root root -"
    ];

    systemd.services.eve-controller-config = {
      description = "Configure EVE Controller Address";

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart =
          "${pkgs.coreutils}/bin/install -D -m 0644 ${
            pkgs.writeText "eve-server" "${cfg.controllerAddress}\n"
          } /config/server";
      };
    };
  };
}
