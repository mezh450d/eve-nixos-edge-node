let
  pkgs = import <nixpkgs> {};

  # Adam 0.0.79 - fixed OCI image
  adamImage = pkgs.dockerTools.pullImage {
    imageName = "lfedge/adam";
    imageDigest =
      "sha256:ddc8f05a3af29890b921fc091178d22b8e0781d0204e3a2dde9559d89f06f40a";
    hash =
      "sha256-5WtKwuIP6wvZ9BjQyYHwfPFbWfYHFZDAS89WRMIRd/E=";
    finalImageName = "lfedge/adam";
    finalImageTag = "0.0.79";
  };

in

pkgs.testers.runNixOSTest {
  name = "eve-adam-network-inspect";

  # VM 1: Real Adam Controller
  nodes.controller = { pkgs, ... }: {

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    networking.firewall.allowedTCPPorts = [ 3333 ];

    systemd.tmpfiles.rules = [
      "d /var/lib/adam-test 0700 root root -"
    ];

    virtualisation.oci-containers.containers.adam = {
      image = "lfedge/adam:0.0.79";
      imageFile = adamImage;
      pull = "never";

      autoStart = true;

      # Adam uses the Controller VM's network
      extraOptions = [
        "--network=host"
      ];

      # Keep certificates and database outside the container
      volumes = [
        "/var/lib/adam-test:/adam/run:rw"
      ];

      cmd = [
        "server"
        "--ip" "0.0.0.0"
        "--port" "3333"
        "--auto-cert"
        "--cert-cn" "controller"
        "--cert-hosts" "controller,127.0.0.1"
      ];
    };

    environment.systemPackages = [
      pkgs.curl
    ];
  };

  # VM 2: Our NixOS Edge Node
  nodes.edge = { pkgs, ... }: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge = {
      enable = true;
      controllerAddress = "controller:3333";
    };

    environment.systemPackages = [
      pkgs.curl
    ];

    virtualisation.cores = 2;
  };

  testScript = ''
    start_all()

    print("=== Starting real Adam Controller ===")

    controller.wait_for_unit("docker.service")
    controller.wait_for_unit("docker-adam.service")

    print("=== Checking Adam HTTPS service ===")

    controller.wait_until_succeeds(
      "curl -kfsS --max-time 5 https://127.0.0.1:3333/ > /dev/null"
    )

    print("Real Adam Controller is running")

    print("=== Checking NixOS Edge Node ===")

    edge.wait_for_unit("multi-user.target")
    edge.wait_for_unit("eve-device-identity.service")
    edge.wait_for_unit("eve-soft-serial.service")
    edge.wait_for_unit("eve-zedagent.service")

    print("=== Checking Controller name resolution ===")

    edge.succeed(
      "getent hosts controller"
    )

    print("=== Testing HTTPS connection to Adam ===")

    edge.wait_until_succeeds(
      "curl -kfsS --max-time 5 https://controller:3333/ > /dev/null"
    )

    print("Edge Node successfully reached Adam via HTTPS")

    print("=== Reading Adam's public TLS certificate ===")

    controller.wait_for_file(
        "/var/lib/adam-test/adam/server.pem"
    )

    server_cert = controller.succeed(
        "cat /var/lib/adam-test/adam/server.pem"
    )

    assert "-----BEGIN CERTIFICATE-----" in server_cert

    print("=== Providing the public certificate to Edge Node ===")

    edge.succeed("mkdir -p /run/adam-trust")

    edge.succeed(
        "cat > /run/adam-trust/server.pem <<'ADAM_CERT'\n"
        + server_cert
        + "\nADAM_CERT"
    )

    print("=== Testing verified HTTPS connection ===")

    edge.succeed(
        "curl --cacert /run/adam-trust/server.pem "
        "-fsS --max-time 10 "
        "https://controller:3333/ > /dev/null"
    )

    print("Adam TLS certificate verification passed")

    print("=== Inspecting Adam-generated EVE configuration ===")

    print(controller.succeed(
      "ls -la /var/lib/adam-test/config"
    ))

    print("=== Listing generated configuration files ===")

    print(controller.succeed(
      "find /var/lib/adam-test/config "
      "-maxdepth 2 -type f | sort"
    ))

    print("Adam bootstrap configuration inspection completed")

    print("=== Inspecting Adam bootstrap content ===")

    address = controller.succeed(
      "cat /var/lib/adam-test/config/server"
    ).strip()

    hosts = controller.succeed(
      "cat /var/lib/adam-test/config/hosts"
    ).strip()

    print("Controller address:", address)
    print("Hosts configuration:", hosts)

    print("=== Comparing Adam public certificates ===")

    root_cert = controller.succeed(
      "cat /var/lib/adam-test/config/root-certificate.pem"
    ).strip()

    server_cert = controller.succeed(
      "cat /var/lib/adam-test/adam/server.pem"
    ).strip()

    signing_cert = controller.succeed(
      "cat /var/lib/adam-test/adam/signing.pem"
    ).strip()

    print("Root matches TLS server certificate:",
          root_cert == server_cert)

    print("Root matches signing certificate:",
          root_cert == signing_cert)

    print("Adam bootstrap inspection completed")


    print("=== Preparing onboarding credentials directory ===")

    controller.succeed(
      "install -d -m 0700 /var/lib/adam-test/onboarding-test"
    )

    print("=== Generating onboarding certificate and key ===")

    controller.succeed(
      "docker exec adam /bin/adam generate "
      "--cn nixos-edge-test "
      "--hosts edge "
      "--out /adam/run/onboarding-test"
    )

    print("=== Checking generated credentials ===")

    controller.succeed(
      "test -s /var/lib/adam-test/onboarding-test/nixos-edge-test.pem"
    )

    controller.succeed(
      "test -s /var/lib/adam-test/onboarding-test/nixos-edge-test-key.pem"
    )

    print(controller.succeed(
      "stat -c '%n | %s bytes | permissions: %a' "
      "/var/lib/adam-test/onboarding-test/*.pem"
    ))

    print("Adam onboarding credentials generated successfully")


    print("=== Reading Edge Node Soft Serial ===")

    edge.succeed("test -s /config/soft_serial")

    soft_serial = edge.succeed(
      "cat /config/soft_serial"
    ).strip()

    assert soft_serial

    print("Edge Node Soft Serial:", soft_serial)

    print("=== Allowing Edge Node onboarding in Adam ===")

    import shlex

    controller.succeed(
      "docker exec adam /bin/adam admin onboard add "
      "--path /adam/run/onboarding-test/nixos-edge-test.pem "
      "--serial " + shlex.quote(soft_serial) + " "
      "--server https://127.0.0.1:3333 "
      "--server-ca /adam/run/adam/server.pem"
    )

    print("=== Checking Adam onboarding allowlist ===")

    result = controller.succeed(
      "docker exec adam /bin/adam admin onboard list "
      "--server https://127.0.0.1:3333 "
      "--server-ca /adam/run/adam/server.pem"
    )

    print(result)

    print("Adam onboarding allowlist test completed")


    print("=== Preparing temporary shared directory ===")

    controller.succeed(
      "install -d -m 0700 /tmp/shared/eve-onboard-test"
    )

    print("=== Preparing credentials for Edge Node ===")

    controller.succeed(
      "install -m 0644 "
      "/var/lib/adam-test/onboarding-test/nixos-edge-test.pem "
      "/tmp/shared/eve-onboard-test/onboard.cert.pem"
    )

    controller.succeed(
      "install -m 0600 "
      "/var/lib/adam-test/onboarding-test/nixos-edge-test-key.pem "
      "/tmp/shared/eve-onboard-test/onboard.key.pem"
    )

    print("=== Provisioning Edge Node credentials ===")

    edge.succeed(
      "install -m 0644 "
      "/tmp/shared/eve-onboard-test/onboard.cert.pem "
      "/config/onboard.cert.pem"
    )

    edge.succeed(
      "install -m 0600 "
      "/tmp/shared/eve-onboard-test/onboard.key.pem "
      "/config/onboard.key.pem"
    )

    print("=== Verifying Edge Node credentials ===")

    edge.succeed("test -s /config/onboard.cert.pem")
    edge.succeed("test -s /config/onboard.key.pem")

    edge.succeed(
      "test \"$(stat -c %a /config/onboard.key.pem)\" = 600"
    )

    print("=== Cleaning up temporary shared files ===")

    controller.succeed(
      "rm -f /tmp/shared/eve-onboard-test/onboard.cert.pem "
      "/tmp/shared/eve-onboard-test/onboard.key.pem"
    )

    print("Edge Node onboarding credentials provisioned successfully")


    print("=== Provisioning Adam root certificate ===")

    controller.succeed(
      "install -m 0644 "
      "/var/lib/adam-test/config/root-certificate.pem "
      "/tmp/shared/eve-onboard-test/root-certificate.pem"
    )

    edge.succeed(
      "install -m 0644 "
      "/tmp/shared/eve-onboard-test/root-certificate.pem "
      "/config/root-certificate.pem"
    )

    edge.succeed(
      "test -s /config/root-certificate.pem"
    )

    controller.succeed(
      "rm -f /tmp/shared/eve-onboard-test/root-certificate.pem"
    )

    print("Adam root certificate provisioned successfully")

    print("=== Checking EVE Client prerequisites ===")

    required_files = [
      "/config/server",
      "/config/root-certificate.pem",
      "/config/soft_serial",
      "/config/device.cert.pem",
      "/config/device.key.pem",
      "/config/onboard.cert.pem",
      "/config/onboard.key.pem",
      "/run/current-system/sw/bin/client",
    ]

    
    missing_files = []

    for path in required_files:
      code, _ = edge.execute("test -s " + path)

      if code == 0:
        print("OK:", path)
      else:
        print("MISSING:", path)
        missing_files.append(path)

    assert not missing_files, (
      "Missing Client prerequisites: " + ", ".join(missing_files)
    )


    print("=== Checking NIM DeviceNetworkStatus ===")

    code, output = edge.execute(
      "ls -l /run/nim/DeviceNetworkStatus/global.json"
    )

    print("DeviceNetworkStatus:", "present" if code == 0 else "missing")

    print("=== Running actual EVE Client ===")

    code, output = edge.execute(
      "timeout 12s "
      "/run/current-system/sw/bin/client "
      "selfRegister getUuid 2>&1"
    )

    print("Client exit code:", code)
    print("Client output:")
    print(output[-6000:])

    if code == 124:
      print("Client was still running after 12 seconds")
    elif code == 0:
      print("Client exited successfully")
      edge.succeed(
        "test -s /persist/status/zedclient/OnboardingStatus/global.json"
      )
      print("OnboardingStatus was published")
    else:
      raise AssertionError(
        "EVE Client exited unexpectedly with code " + str(code)
      )

    print("Client startup diagnostic completed")


    print("=== Inspecting NixOS Edge Network ===")

    print("=== IPv4 interfaces ===")
    print(edge.succeed(
      "ip -4 -o addr show scope global"
    ))

    print("=== IPv4 routes ===")
    print(edge.succeed(
      "ip -4 route show"
    ))

    print("=== Controller DNS resolution ===")
    print(edge.succeed(
      "getent ahostsv4 controller"
    ))

    print("=== Network Status Pubsub directory ===")
    print(edge.succeed(
      "ls -ld /run/nim "
      "/run/nim/DeviceNetworkStatus "
      "/run/zedbox 2>&1 || true"
    ))

    print("Network inspection completed")
      '';
}
