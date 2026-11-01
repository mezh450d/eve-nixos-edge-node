let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-edge-module-smoke";

  nodes.machine = { ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    machine.wait_for_unit("eve-edge-demo.service")

    machine.succeed(
      "systemctl is-active --quiet eve-edge-demo.service"
    )

    machine.succeed(
      "grep -qx module-enabled /etc/eve-edge/status"
    )

    output = machine.succeed(
      "journalctl -u eve-edge-demo.service --no-pager -o cat"
    )

    assert "eve-edge-module-started" in output

    print("Module test PASSED")
  '';
}
