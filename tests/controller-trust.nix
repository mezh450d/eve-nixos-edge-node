let
  pkgs = import <nixpkgs> {};
in

pkgs.testers.runNixOSTest {
  name = "eve-controller-trust";

  nodes.machine = { ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge = {
      enable = true;

      controllerAddress = "mydomain.adam:3333";

      controllerRootCertificateFile =
        /home/meng/work/eve-phase1/dist/default-certs/root-certificate.pem;

      v2TlsBaseRootCertificatesFile =
        /home/meng/work/eve-phase1/dist/default-certs/v2tlsbaseroot-certificates.pem;
    };

    environment.systemPackages = [
      pkgs.openssl
    ];

    virtualisation.cores = 2;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    print("=== Checking Controller Trust service ===")

    machine.wait_for_unit("eve-controller-trust.service")

    machine.succeed(
      "systemctl is-active --quiet eve-controller-trust.service"
    )

    print("=== Checking Controller configuration ===")

    machine.wait_for_unit("eve-controller-config.service")

    machine.succeed(
      "test \"$(cat /config/server)\" = mydomain.adam:3333"
    )

    print("=== Checking certificate files ===")

    machine.succeed(
      "test -s /config/root-certificate.pem"
    )

    machine.succeed(
      "test -s /config/v2tlsbaseroot-certificates.pem"
    )

    print("=== Verifying Root Certificate ===")

    machine.succeed(
      "openssl x509 -in /config/root-certificate.pem -noout"
    )

    root_hash = machine.succeed(
      "sha256sum /config/root-certificate.pem"
    ).split()[0]

    assert root_hash == "43771167f78e48d92318389c249551338c22c262895376a439b13e7e0d16762c"

    print("=== Checking V2 TLS certificate bundle ===")

    count = int(machine.succeed(
      "grep -c 'BEGIN CERTIFICATE' /config/v2tlsbaseroot-certificates.pem"
    ).strip())

    assert count == 129, f"Expected 129 certificates, found {count}"

    print("Controller trust certificates verified")
  '';
}
