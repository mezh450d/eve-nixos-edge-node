{
  config,
  lib,
  ...
}: let
  cfg = config.services.eve-edge;
in {
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "f+ /run/eve-release 0644 root root - NixOS-${config.system.nixos.version}"
    ];
  };
}
