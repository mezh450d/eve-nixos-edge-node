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

  nimLauncher = pkgs.runCommand "eve-nim-launcher" {} ''
    mkdir -p $out/bin
    ln -s ${pillar}/bin/zedbox $out/bin/nim
  '';
in {
  options.services.eve-edge.nim.enable =
    lib.mkEnableOption "native EVE Network Interface Manager";

  config = lib.mkIf (cfg.enable && cfg.nim.enable) {
    systemd.tmpfiles.rules = [
      "d /run/watchdog 0755 root root -"
      "d /run/watchdog/file 0755 root root -"
    ];

    systemd.services.eve-nim = {
      description = "Start native EVE NIM";

      wantedBy = ["multi-user.target"];

      requires = [
        "eve-zedbox.service"
        "eve-zedagent.service"
      ];

      after = [
        "eve-zedbox.service"
        "eve-zedagent.service"
      ];

      preStart = ''
        echo "Waiting for zedbox to be ready..."

        for i in $(${pkgs.coreutils}/bin/seq 1 50); do
          if [ -S /run/zedbox/ServiceInitStatus.sock ]; then
            echo "zedbox socket is ready"
            exit 0
          fi

          ${pkgs.coreutils}/bin/sleep 0.2
        done

        echo "ERROR: zedbox socket was not ready" >&2
        exit 1
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${nimLauncher}/bin/nim";
      };
    };
  };
}
