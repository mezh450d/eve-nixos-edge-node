{ config, lib, pkgs, ... }:

let
  cfg = config.services.eve-edge;

  initSoftSerial = pkgs.writeShellScript "eve-init-soft-serial" ''
    set -eu

    serial=/config/soft_serial

    ${pkgs.coreutils}/bin/install -d -m 0755 /config

    if [ -L "$serial" ]; then
      echo "ERROR: soft_serial must not be a symlink" >&2
      exit 1
    fi

    if [ -e "$serial" ]; then
      if [ ! -f "$serial" ] || [ ! -s "$serial" ]; then
        echo "ERROR: Existing soft_serial is invalid" >&2
        exit 1
      fi

      echo "Existing EVE Soft Serial found. Keeping it."
    else
      echo "Generating new EVE Soft Serial"

      umask 077
      tmp=$(${pkgs.coreutils}/bin/mktemp /config/.soft_serial.XXXXXXXX)
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

      ${pkgs.coreutils}/bin/cat /proc/sys/kernel/random/uuid > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -T "$tmp" "$serial"
    fi

    test -s "$serial"
    echo "EVE Soft Serial is ready"
  '';

in
{
  config = lib.mkIf cfg.enable {
    systemd.services.eve-soft-serial = {
      description = "Initialize EVE Soft Serial";

      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${initSoftSerial}";
      };
    };
  };
}
