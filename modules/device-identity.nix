{ config, lib, pkgs, ... }:

let
  cfg = config.services.eve-edge;

  initializeIdentity = pkgs.writeShellScript "eve-init-identity" ''
    set -eu

    cert=/config/device.cert.pem
    key=/config/device.key.pem

    ${pkgs.coreutils}/bin/install -d -m 0755 /config

    # Refuse symbolic links for identity files.
    if [ -L "$cert" ] || [ -L "$key" ]; then
      echo "ERROR: Identity files must not be symlinks" >&2
      exit 1
    fi

    if [ -s "$cert" ] && [ -s "$key" ]; then
      echo "Existing EVE device identity found. Keeping it."

    elif [ -e "$cert" ] || [ -e "$key" ]; then
      echo "ERROR: Incomplete device identity. Refusing to overwrite it." >&2
      exit 1

    else
      echo "Generating new EVE software device identity"
      umask 077
      /run/current-system/sw/bin/tpmmgr createSoftDeviceCert
    fi

    # Verify the files exist and the private key is protected.
    test -s "$cert"
    test -s "$key"

    if [ "$(${pkgs.coreutils}/bin/stat -c %a "$key")" != "600" ]; then
      echo "ERROR: Private key permissions must be 600" >&2
      exit 1
    fi

    echo "EVE device identity is ready"
  '';

in
{
  config = lib.mkIf cfg.enable {
    systemd.services.eve-device-identity = {
      description = "Initialize EVE Device Identity";

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${initializeIdentity}";
      };
    };
  };
}
