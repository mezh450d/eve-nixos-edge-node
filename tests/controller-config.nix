let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-controller-config";

  nodes.machine = { ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge = {
      enable = true;

      # Test address, not a real controller
      controllerAddress = "controller.example.invalid:8080";
    };

    virtualisation.cores = 2;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    print("=== Checking Controller configuration ===")

    machine.wait_for_unit("eve-controller-config.service")

    machine.succeed(
      "systemctl is-active --quiet eve-controller-config.service"
    )

    machine.succeed(
      "test -f /config/server"
    )

    machine.succeed(
      "grep -Fxq 'controller.example.invalid:8080' /config/server"
    )

    print("Controller address configuration verified")
  '';
}
