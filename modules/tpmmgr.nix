{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.eve-edge;

  pillar = import ../pillar.nix {
    inherit pkgs;
  };

  tpmmgrLauncher = pkgs.runCommand "eve-tpmmgr-launcher" {} ''
    mkdir -p "$out/bin"
    ln -s ${pillar}/bin/zedbox "$out/bin/tpmmgr"
  '';
in {
  options.services.eve-edge.tpmmgr.enable =
    lib.mkEnableOption "native EVE TPM Manager integration";

  config = lib.mkIf (cfg.enable && cfg.tpmmgr.enable) {
    systemd.services.eve-tpmmgr = {
      description = "Start native EVE TPM Manager";

      # Started explicitly during Integration Test.
      # Do not automatically start on the NixOS host.
      requires = [
        "eve-zedbox.service"
        "eve-device-identity.service"
      ];

      after = [
        "eve-zedbox.service"
        "eve-device-identity.service"
      ];

      preStart = ''
        for i in $(${pkgs.coreutils}/bin/seq 1 50); do
          if [ -S /run/zedbox/ServiceInitStatus.sock ]; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 0.2
        done

        echo "zedbox socket was not ready" >&2
        exit 1
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tpmmgrLauncher}/bin/tpmmgr";
      };
    };
  };
}
