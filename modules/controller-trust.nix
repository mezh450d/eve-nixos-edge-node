{ config, lib, pkgs, ... }:

let
  cfg = config.services.eve-edge;

  haveCertificates =
    cfg.controllerRootCertificateFile != null
    && cfg.v2TlsBaseRootCertificatesFile != null;

  installTrust = pkgs.writeShellScript "eve-install-controller-trust" ''
    set -eu

    ${pkgs.coreutils}/bin/install -d -m 0755 /config

    for file in \
      /config/root-certificate.pem \
      /config/v2tlsbaseroot-certificates.pem
    do
      if [ -L "$file" ]; then
        echo "ERROR: Certificate destination must not be a symlink" >&2
        exit 1
      fi
    done

    ${pkgs.coreutils}/bin/install -m 0644 \
      ${cfg.controllerRootCertificateFile} \
      /config/root-certificate.pem

    ${pkgs.coreutils}/bin/install -m 0644 \
      ${cfg.v2TlsBaseRootCertificatesFile} \
      /config/v2tlsbaseroot-certificates.pem

    echo "EVE Controller trust certificates are ready"
  '';

in
{
  options.services.eve-edge = {
    controllerRootCertificateFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Controller root certificate file";
    };

    v2TlsBaseRootCertificatesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Controller V2 TLS trust certificate bundle";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          (cfg.controllerRootCertificateFile == null)
          == (cfg.v2TlsBaseRootCertificatesFile == null);
        message = "Both EVE Controller trust certificate files must be configured together.";
      }
    ];

    systemd.services = lib.mkIf haveCertificates {
      eve-controller-trust = {
        description = "Install EVE Controller Trust Certificates";

        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${installTrust}";
        };
      };
    };
  };
}
