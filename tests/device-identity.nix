let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-device-identity";

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

    print("=== Checking automatic identity generation ===")

    machine.wait_for_unit("eve-device-identity.service")

    machine.succeed(
      "systemctl is-active --quiet eve-device-identity.service"
    )

    machine.succeed("test -s /config/device.cert.pem")
    machine.succeed("test -s /config/device.key.pem")

    machine.succeed(
      "test \"$(stat -c %a /config/device.key.pem)\" = 600"
    )

    print("=== Recording the original identity ===")

    cert_before = machine.succeed(
      "sha256sum /config/device.cert.pem"
    ).split()[0]

    key_before = machine.succeed(
      "sha256sum /config/device.key.pem"
    ).split()[0]

    print("=== Restarting identity service ===")

    machine.succeed(
      "systemctl restart eve-device-identity.service"
    )

    cert_after = machine.succeed(
      "sha256sum /config/device.cert.pem"
    ).split()[0]

    key_after = machine.succeed(
      "sha256sum /config/device.key.pem"
    ).split()[0]

    assert cert_before == cert_after, "Certificate changed"
    assert key_before == key_after, "Private key changed"

    print("Identity preserved after service restart")

    print("=== Rebooting the VM ===")

    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("eve-device-identity.service")

    cert_reboot = machine.succeed(
      "sha256sum /config/device.cert.pem"
    ).split()[0]

    key_reboot = machine.succeed(
      "sha256sum /config/device.key.pem"
    ).split()[0]

    assert cert_before == cert_reboot, "Certificate changed after reboot"
    assert key_before == key_reboot, "Private key changed after reboot"

    print("Identity preserved after VM reboot")
    print("Device Identity Module verified")
  '';
}
