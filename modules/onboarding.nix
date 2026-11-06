{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.eve-edge;
in {
  options.services.eve-edge.onboarding.enable =
    lib.mkEnableOption "native EVE client onboarding";

  options.services.eve-edge.onboarding.readyFile = lib.mkOption {
    type = lib.types.str;
    default = "/config/onboarding.ready";
    description = ''
      Runtime marker created by the credential provider after
      all required onboarding credentials have been installed.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.onboarding.enable) {
    assertions = [
      {
        assertion = cfg.nim.enable;
        message = "EVE onboarding currently requires native NIM.";
      }
      {
        assertion = cfg.controllerAddress != null;
        message = "EVE onboarding requires a controller address.";
      }
    ];

    systemd.paths.eve-onboarding = {
      description = "Watch for EVE Onboarding Credentials";

      wantedBy = ["multi-user.target"];

      pathConfig = {
        PathExists = cfg.onboarding.readyFile;
        Unit = "eve-onboarding.service";
      };
    };

    systemd.services.eve-onboarding = {
      description = "EVE Edge Node Initial Onboarding";

      requires = [
        "eve-zedbox.service"
        "eve-nim.service"
        "eve-device-identity.service"
        "eve-soft-serial.service"
        "eve-controller-config.service"
      ];

      after = [
        "eve-zedbox.service"
        "eve-nim.service"
        "eve-device-identity.service"
        "eve-soft-serial.service"
        "eve-controller-config.service"
      ];

      path = with pkgs; [
        coreutils
        dmidecode
      ];

      preStart = ''
        set -eu

        echo "Checking EVE onboarding prerequisites..."

        for file in \
          /config/server \
          /config/root-certificate.pem \
          /config/onboard.cert.pem \
          /config/onboard.key.pem \
          /config/device.cert.pem \
          /config/device.key.pem \
          /config/soft_serial
        do
          if [ -L "$file" ] || [ ! -s "$file" ]; then
            echo "Missing or invalid onboarding prerequisite: $file" >&2
            exit 1
          fi
        done

        if [ "$(${pkgs.coreutils}/bin/stat -c %a /config/onboard.key.pem)" != "600" ]; then
          echo "Onboarding private key must have mode 600" >&2
          exit 1
        fi

        echo "Waiting for native NIM DPC_SUCCESS..."

        ready=0

        for i in $(${pkgs.coreutils}/bin/seq 1 120); do
          if [ -s /run/nim/DeviceNetworkStatus/global.json ] &&
             ${pkgs.jq}/bin/jq -e '.State == 3' \
               /run/nim/DeviceNetworkStatus/global.json >/dev/null 2>&1
          then
            ready=1
            break
          fi

          ${pkgs.coreutils}/bin/sleep 1
        done

        if [ "$ready" != "1" ]; then
          echo "NIM did not reach DPC_SUCCESS" >&2
          exit 1
        fi

        echo "NIM network verification succeeded"
      '';

      postStart = ''
        set -eu

        echo "Checking EVE onboarding result..."

        for i in $(${pkgs.coreutils}/bin/seq 1 15); do
          if [ -s /persist/status/uuid ] &&
             [ -s /persist/status/zedclient/OnboardingStatus/global.json ]
          then
            echo "Device UUID and OnboardingStatus are present"
            exit 0
          fi

          ${pkgs.coreutils}/bin/sleep 1
        done

        echo "Client exited without publishing the expected onboarding result" >&2
        exit 1
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = "/run/current-system/sw/bin/client selfRegister getUuid";

        TimeoutStartSec = "180s";
      };
    };
  };
}
