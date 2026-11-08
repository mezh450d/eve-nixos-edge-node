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

  nodeagentLauncher = pkgs.runCommand "eve-nodeagent-launcher" {} ''
    mkdir -p "$out/bin"
    ln -s ${pillar}/bin/zedbox "$out/bin/nodeagent"
  '';
in {
  options.services.eve-edge.nodeagent.enable =
    lib.mkEnableOption "native EVE NodeAgent integration";

  config = lib.mkIf (cfg.enable && cfg.nodeagent.enable) {
    # Agent execution happens inside the main zedbox process.
    systemd.services.eve-zedbox.environment.EVE_NODEAGENT_BOOT_BACKEND = "nixos";
    environment.systemPackages = [
      nodeagentLauncher
    ];

    systemd.services.eve-nodeagent = {
      description = "Start native EVE NodeAgent";

      # Start automatically after zedagent when onboarding is enabled.
      wantedBy = lib.optionals cfg.onboarding.enable [
        "eve-zedagent.service"
      ];

      requires =
        ["eve-zedbox.service"]
        ++ lib.optionals cfg.onboarding.enable [
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
        ExecStart = "${nodeagentLauncher}/bin/nodeagent";
      };
    };
  };
}
