let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-soft-serial";

  nodes.machine = { ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge.enable = true;
    virtualisation.cores = 2;
  };

  testScript = ''
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    print("=== Checking Soft Serial generation ===")

    machine.wait_for_unit("eve-soft-serial.service")

    machine.succeed("test -s /config/soft_serial")

    machine.succeed(
      "grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' /config/soft_serial"
    )

    serial_before = machine.succeed(
      "cat /config/soft_serial"
    ).strip()

    print("=== Restarting Soft Serial service ===")

    machine.succeed(
      "systemctl restart eve-soft-serial.service"
    )

    serial_after = machine.succeed(
      "cat /config/soft_serial"
    ).strip()

    assert serial_before == serial_after, "Soft Serial changed"

    print("Soft Serial preserved after service restart")

    print("=== Rebooting VM ===")

    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("eve-soft-serial.service")

    serial_reboot = machine.succeed(
      "cat /config/soft_serial"
    ).strip()

    assert serial_before == serial_reboot, "Soft Serial changed after reboot"

    print("Soft Serial preserved after VM reboot")
    print("Soft Serial Module verified")
  '';
}
