let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-zedagent-auto-start";

  nodes.machine = { ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge.enable = true;

    virtualisation.cores = 2;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    print("=== Checking systemd services ===")

    machine.succeed(
      "systemctl is-active --quiet eve-zedbox.service"
    )

    machine.wait_for_unit("eve-zedagent.service")

    machine.succeed(
      "systemctl is-active --quiet eve-zedagent.service"
    )

    print("=== Checking runtime directories ===")

    machine.succeed(
      "test -d /persist/checkpoint"
    )

    print("=== Checking real zedagent startup ===")

    machine.wait_for_file("/run/zedagent.pid")

    machine.wait_until_succeeds(
      "test -S /run/zedagent/AppInstanceConfig.sock"
    )

    machine.wait_until_succeeds(
      "journalctl -u eve-zedbox.service "
      "--no-pager -o cat | "
      "grep -Fq 'Initialized GlobalConfig'"
    )

    print("=== Service status ===")

    print(machine.succeed(
      "systemctl status eve-zedagent.service --no-pager"
    ))

    print("zedagent automatic startup verified")
  '';
}
