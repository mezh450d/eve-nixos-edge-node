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

  options.services.eve-edge.nim.dhcpDnsHook.enable =
    lib.mkEnableOption "DHCP DNS forwarding for native EVE NIM";

  config = lib.mkIf (cfg.enable && cfg.nim.enable) {
    # Forward DHCP-provided DNS information to native EVE NIM.
    # Optional because this integrates with the system dhcpcd hook.
    environment.etc = lib.mkIf cfg.nim.dhcpDnsHook.enable {
      "dhcpcd.exit-hook".text = ''
        case "$reason" in
          BOUND|RENEW|REBIND|REBOOT|INFORM|STATIC)
            if [ -n "$new_domain_name_servers" ]; then
              mkdir -p /run/dhcpcd/resolv.conf

              {
                for server in $new_domain_name_servers; do
                  printf 'nameserver %s\n' "$server"
                done

                if [ -n "$new_domain_search" ]; then
                  printf 'search %s\n' "$new_domain_search"
                fi
              } > "/run/dhcpcd/resolv.conf/$interface.dhcp"
            fi
            ;;

          EXPIRE|FAIL|RELEASE|STOP)
            rm -f "/run/dhcpcd/resolv.conf/$interface.dhcp"
            ;;
        esac
      '';
    };

    systemd.services.eve-zedbox.path = with pkgs; [
      dhcpcd
      iptables
      util-linux
    ];

    systemd.services.eve-zedbox.serviceConfig.BindReadOnlyPaths = [
      "${pkgs.dhcpcd}/bin/dhcpcd:/sbin/dhcpcd"
      "${pkgs.dnsmasq}/bin/dnsmasq:/usr/sbin/dnsmasq"
    ];

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
