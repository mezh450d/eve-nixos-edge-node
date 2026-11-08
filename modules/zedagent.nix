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

  agentLaunchers = pkgs.runCommand "eve-agent-launchers" {} ''
    mkdir -p $out/bin

    ln -s ${pillar}/bin/zedbox $out/bin/zedbox
    ln -s ${pillar}/bin/zedbox $out/bin/zedagent
    ln -s ${pillar}/bin/zedbox $out/bin/client
    ln -s ${pillar}/bin/zedbox $out/bin/tpmmgr
  '';
in {
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      agentLaunchers
    ];

    # Prepare basic EVE directories
    systemd.tmpfiles.rules = [
      "d /persist 0755 root root -"
      "d /persist/checkpoint 0755 root root -"
    ];

    # Main zedbox process
    systemd.services.eve-zedbox = {
      description = "EVE Pillar zedbox";

      wantedBy = ["multi-user.target"];

      path = with pkgs; [
        dmidecode
      ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${agentLaunchers}/bin/zedbox";
        Restart = "no";
      };
    };

    # Request zedagent startup

    systemd.services.eve-zedagent = {
      description = "Start EVE zedagent";

      wantedBy =
        if cfg.onboarding.enable
        then ["eve-onboarding.service"]
        else ["multi-user.target"];

      requires =
        ["eve-zedbox.service"]
        ++ lib.optionals cfg.onboarding.enable [
          "eve-onboarding.service"
        ]
        ++ lib.optionals cfg.tpmmgr.enable [
          "eve-tpmmgr.service"
        ];

      after =
        ["eve-zedbox.service"]
        ++ lib.optionals cfg.onboarding.enable [
          "eve-onboarding.service"
        ]
        ++ lib.optionals cfg.tpmmgr.enable [
          "eve-tpmmgr.service"
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
        ExecStart = "${agentLaunchers}/bin/zedagent";
      };
    };
  };
}
