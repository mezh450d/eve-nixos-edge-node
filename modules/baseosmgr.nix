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

  baseosmgrLauncher = pkgs.runCommand "eve-baseosmgr-launcher" {} ''
    mkdir -p "$out/bin"
    ln -s ${pillar}/bin/zedbox "$out/bin/baseosmgr"
  '';
in {
  options.services.eve-edge.baseosmgr.enable =
    lib.mkEnableOption "native EVE BaseOS Manager integration";

  config = lib.mkIf (cfg.enable && cfg.baseosmgr.enable) {
    environment.systemPackages = [
      baseosmgrLauncher
    ];

    # The real agent executes inside the zedbox process.
    systemd.services.eve-zedbox.environment.EVE_BASEOSMGR_BOOT_BACKEND = "nixos";

    systemd.services.eve-baseosmgr = {
      description = "Start native EVE BaseOS Manager";

      # Start automatically after onboarding.
      wantedBy = lib.optionals cfg.onboarding.enable [
        "eve-onboarding.service"
      ];

      requires =
        ["eve-zedbox.service"]
        ++ lib.optionals cfg.onboarding.enable [
          "eve-onboarding.service"
        ];

      after =
        ["eve-zedbox.service"]
        ++ lib.optionals cfg.onboarding.enable [
          "eve-onboarding.service"
          "eve-zedagent.service"
        ]
        ++ lib.optionals cfg.nodeagent.enable [
          "eve-nodeagent.service"
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
        ExecStart = "${baseosmgrLauncher}/bin/baseosmgr";
      };
    };
  };
}
