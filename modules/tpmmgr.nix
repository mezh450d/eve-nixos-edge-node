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

  softCertsEnabled = cfg.tpmmgr.softwareCertificates.enable;
in {
  options.services.eve-edge.tpmmgr = {
    enable = lib.mkEnableOption "native EVE TPM Manager integration";

    softwareCertificates.enable =
      lib.mkEnableOption "native EVE software certificate initialization";
  };

  config = lib.mkIf (cfg.enable && cfg.tpmmgr.enable) {
    systemd.services.eve-soft-certs = lib.mkIf softCertsEnabled {
      description = "Initialize EVE Software Certificates";

      requires = ["eve-device-identity.service"];
      after = ["eve-device-identity.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -eu

        certdir=/persist/certs

        if [ -L "$certdir" ]; then
          echo "ERROR: Certificate directory must not be a symlink" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/install -d -m 0700 "$certdir"

        for name in ecdh attest; do
          cert="$certdir/$name.cert.pem"
          key="$certdir/$name.key.pem"

          if [ -L "$cert" ] || [ -L "$key" ]; then
            echo "ERROR: Certificate files must not be symlinks: $name" >&2
            exit 1
          fi

          if [ -e "$cert" ] && [ ! -s "$cert" ]; then
            echo "ERROR: Empty certificate: $cert" >&2
            exit 1
          fi

          if [ -e "$key" ] && [ ! -s "$key" ]; then
            echo "ERROR: Empty private key: $key" >&2
            exit 1
          fi

          if [ -e "$cert" ] && [ ! -e "$key" ]; then
            echo "ERROR: Missing private key: $key" >&2
            exit 1
          fi

          if [ -e "$key" ] && [ ! -e "$cert" ]; then
            echo "ERROR: Missing certificate: $cert" >&2
            exit 1
          fi
        done

        echo "Initializing native EVE software certificates"

        ${tpmmgrLauncher}/bin/tpmmgr createSoftCerts

        for name in ecdh attest; do
          cert="$certdir/$name.cert.pem"
          key="$certdir/$name.key.pem"

          test -s "$cert"
          test -s "$key"

          ${pkgs.coreutils}/bin/chmod 0600 "$key"
        done

        echo "EVE software certificates are ready"
      '';
    };

    systemd.services.eve-tpmmgr = {
      description = "Start native EVE TPM Manager";

      # Started explicitly in the isolated Integration Test VM.
      requires =
        [
          "eve-zedbox.service"
          "eve-device-identity.service"
        ]
        ++ lib.optionals softCertsEnabled [
          "eve-soft-certs.service"
        ];

      after =
        [
          "eve-zedbox.service"
          "eve-device-identity.service"
        ]
        ++ lib.optionals softCertsEnabled [
          "eve-soft-certs.service"
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
