let
  pkgs = import <nixpkgs> {};

  # Adam 0.0.79 - fixed OCI image
  adamImage = pkgs.dockerTools.pullImage {
    imageName = "lfedge/adam";
    imageDigest = "sha256:ddc8f05a3af29890b921fc091178d22b8e0781d0204e3a2dde9559d89f06f40a";
    hash = "sha256-5WtKwuIP6wvZ9BjQyYHwfPFbWfYHFZDAS89WRMIRd/E=";
    finalImageName = "lfedge/adam";
    finalImageTag = "0.0.79";
  };
in
  pkgs.testers.runNixOSTest {
    name = "eve-adam-network-inspect";

    # VM 1: Real Adam Controller
    nodes.controller = {pkgs, ...}: {
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;

      virtualisation.docker.enable = true;
      virtualisation.oci-containers.backend = "docker";

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "192.168.1.100,192.168.1.150,255.255.255.0,1h";
          address = "/controller/192.168.1.1";
          "dhcp-option" = "option:dns-server,192.168.1.1";
        };
      };

      networking.firewall.allowedUDPPorts = [53 67];
      networking.firewall.allowedTCPPorts = [53 3333];

      systemd.tmpfiles.rules = [
        "d /var/lib/adam-test 0700 root root -"
      ];

      # Generate CA-signed certificates for Adam in this test VM.
      systemd.services.adam-test-certs = {
        description = "Generate CA-signed certificates for Adam integration test";

        path = with pkgs; [
          openssl
          coreutils
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -eu

          certdir=/var/lib/adam-test/adam
          mkdir -p "$certdir"
          umask 077

          # Generate Root CA
          openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
            -keyout "$certdir/ca-key.pem" \
            -out "$certdir/ca.pem" \
            -subj "/CN=Adam Integration Test CA" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "keyUsage=critical,keyCertSign,cRLSign"

          # Generate certificates signed by the same CA
          for name in server signing encrypt; do
            cn="$name"
            if [ "$name" = server ]; then
              cn=controller
            fi

            openssl req -new -newkey rsa:2048 -nodes \
              -keyout "$certdir/$name-key.pem" \
              -out "$certdir/$name.csr" \
              -subj "/CN=$cn"

            {
              echo 'basicConstraints=critical,CA:FALSE'
              echo 'keyUsage=critical,digitalSignature,keyEncipherment'
              echo 'extendedKeyUsage=serverAuth'

              if [ "$name" = server ]; then
                echo 'subjectAltName=DNS:controller,IP:127.0.0.1'
              fi
            } > "$certdir/$name.ext"

            openssl x509 -req -in "$certdir/$name.csr" \
              -CA "$certdir/ca.pem" \
              -CAkey "$certdir/ca-key.pem" \
              -CAcreateserial \
              -out "$certdir/$name.pem" \
              -days 365 -sha256 \
              -extfile "$certdir/$name.ext"
          done

          # Verify all certificates
          openssl verify -CAfile "$certdir/ca.pem" \
            "$certdir/server.pem" \
            "$certdir/signing.pem" \
            "$certdir/encrypt.pem"
        '';
      };

      # Start Adam only after certificates are generated.
      systemd.services.docker-adam = {
        requires = ["adam-test-certs.service"];
        after = ["adam-test-certs.service"];
      };

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
          "--ip"
          "0.0.0.0"
          "--port"
          "3333"
        ];
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.openssl
      ];
    };

    # VM 2: Our NixOS Edge Node
    nodes.edge = {
      pkgs,
      lib,
      ...
    }: {
      imports = [
        ../modules/edge-node.nix
      ];

      # Test-only: start Pillar after onboarding credentials are ready.
      systemd.services.eve-zedbox.wantedBy = lib.mkForce [];
      systemd.services.eve-zedagent.wantedBy = lib.mkForce [];
      systemd.services.eve-nim.wantedBy = lib.mkForce [];

      systemd.services.eve-nim.unitConfig.ConditionPathExists = "/config/onboard.cert.pem";

      services.eve-edge = {
        enable = true;
        nim.enable = true;
        nim.dhcpDnsHook.enable = true;
        onboarding.enable = true;
        controllerAddress = "controller:3333";
      };

      # Network ownership belongs to native NIM in this test VM.
      networking.useDHCP = false;
      networking.dhcpcd.enable = false;

      # Let NIM acquire the address on the test VLAN.
      virtualisation.interfaces.eth1 = {
        vlan = 1;
        assignIP = false;
      };

      # Temporary compatibility for upstream EVE dhcpcd.

      environment.etc."dhcpcd.conf".text = ''
          option domain_name_servers
          option domain_name
          option domain_search

        # NIM manages /etc/resolv.conf itself.
          nohook resolv.conf
      '';

      environment.systemPackages = [
        pkgs.curl
        pkgs.dhcpcd
        pkgs.jq
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


      print("=== Installing the root CA trusted by EVE ===")

      controller.succeed(
          "install -m 0644 "
          "/var/lib/adam-test/adam/ca.pem "
          "/var/lib/adam-test/config/root-certificate.pem"
      )

      print(controller.succeed(
          "openssl verify "
          "-CAfile /var/lib/adam-test/adam/ca.pem "
          "/var/lib/adam-test/adam/server.pem "
          "/var/lib/adam-test/adam/signing.pem "
          "/var/lib/adam-test/adam/encrypt.pem"
      ))

      print("Adam certificate chain verified")


      print("=== Checking NixOS Edge Node ===")

      edge.wait_for_unit("multi-user.target")

      print("=== Checking Module-provided DHCP DNS hook ===")

      edge.succeed(
          "test -s /etc/dhcpcd.exit-hook"
      )

      edge.succeed(
          "grep -Fq 'new_domain_name_servers' /etc/dhcpcd.exit-hook"
      )

      print("Module-provided DHCP DNS hook is present")

      edge.wait_for_unit("eve-device-identity.service")
      edge.wait_for_unit("eve-soft-serial.service")

      # Pillar must not start before onboarding credentials exist.
      edge.succeed("! systemctl is-active --quiet eve-zedbox.service")
      edge.succeed("test ! -e /run/nim.pid")

      print("=== Reading the Adam test root CA ===")

      controller.wait_for_file(
          "/var/lib/adam-test/config/root-certificate.pem"
      )

      root_ca = controller.succeed(
          "cat /var/lib/adam-test/config/root-certificate.pem"
      )

      assert "-----BEGIN CERTIFICATE-----" in root_ca

      print("=== Providing the public root CA to Edge Node ===")

      edge.succeed("mkdir -p /run/adam-trust")

      edge.succeed(
          "cat > /run/adam-trust/server.pem <<'ADAM_CERT'\n"
          + root_ca
          + "\nADAM_CERT"
      )

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


      print("=== Generating ECDSA onboarding credentials ===")

      controller.succeed(
          "openssl ecparam -name prime256v1 -genkey -noout "
          "-out /var/lib/adam-test/onboarding-test/nixos-edge-test-key.pem"
      )

      controller.succeed(
          "openssl req -new -x509 -sha256 -days 365 "
          "-key /var/lib/adam-test/onboarding-test/nixos-edge-test-key.pem "
          "-out /var/lib/adam-test/onboarding-test/nixos-edge-test.pem "
          "-subj '/CN=nixos-edge-test' "
          "-addext 'basicConstraints=critical,CA:FALSE' "
          "-addext 'keyUsage=critical,digitalSignature' "
          "-addext 'extendedKeyUsage=clientAuth' "
          "-addext 'subjectAltName=DNS:edge'"
      )

      controller.succeed(
          "openssl x509 "
          "-in /var/lib/adam-test/onboarding-test/nixos-edge-test.pem "
          "-noout -text | grep -q 'id-ecPublicKey'"
      )

      print("ECDSA P-256 onboarding credentials generated successfully")


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

      print("=== Signaling that onboarding credentials are ready ===")

      edge.succeed(
          "test -s /config/onboard.cert.pem "
          "&& test -s /config/onboard.key.pem "
          "&& test -s /config/root-certificate.pem"
      )

      edge.succeed(
          "install -m 0600 /dev/null /config/onboarding.ready"
      )

      print("Onboarding credentials ready marker created")

      print("=== Starting native NIM after credential provisioning ===")

      edge.succeed(
          "test -s /config/onboard.cert.pem && "
          "test -s /config/onboard.key.pem && "
          "test -s /config/root-certificate.pem"
      )

      print("=== Starting zedbox ===")
      edge.succeed("systemctl start eve-zedbox.service")
      edge.wait_for_unit("eve-zedbox.service")

      print("=== Starting native NIM ===")
      edge.succeed("systemctl start eve-nim.service")
      edge.wait_for_unit("eve-nim.service")

      edge.wait_until_succeeds(
          "test -s /run/nim/DeviceNetworkStatus/global.json",
          timeout=90
      )

      print("Native NIM started with onboarding credentials")

      print("=== Testing Adam connectivity after NIM startup ===")

      edge.wait_until_succeeds(
          "curl -kfsS --max-time 5 "
          "https://controller:3333/ > /dev/null",
          timeout=90
      )

      edge.wait_until_succeeds(
          "curl --cacert /run/adam-trust/server.pem "
          "-fsS --max-time 5 "
          "https://controller:3333/ > /dev/null",
          timeout=90
      )

      print("Edge Node reached Adam with verified TLS")


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

      print("=== Checking native NIM with real Adam ===")

      edge.wait_for_unit("eve-nim.service")

      edge.wait_until_succeeds(
          "test -s /run/nim/DeviceNetworkStatus/global.json",
          timeout=90
      )

      print(
          edge.succeed(
              "cat /run/nim/DeviceNetworkStatus/global.json"
          )
      )

      print("=== Checking Edge Node network ===")
      print(edge.succeed("ip -br addr"))
      print(edge.succeed("ip -4 route"))

      print("=== Checking Adam connectivity after NIM startup ===")

      edge.wait_until_succeeds(
          "curl --cacert /run/adam-trust/server.pem "
          "-fsS --max-time 5 "
          "https://controller:3333/ > /dev/null",
          timeout=90
      )

      print("Native NIM Edge Node can reach real Adam")

      print("=== Inspecting DHCP lease DNS options ===")

      code, output = edge.execute(
          "dhcpcd -U -4 eth1 2>&1"
      )
      print("DHCP lease query exit code:", code)
      print(output)


      print("=== Verifying DHCP supplied DNS servers ===")

      edge.wait_until_succeeds(
          "dhcpcd -U -4 eth1 | grep -q '^domain_name_servers='",
          timeout=30
      )

      print("DHCP DNS option received successfully")


      print("=== Inspecting dhcpcd hook state ===")
      print(edge.succeed(
          "ls -laR /run/dhcpcd 2>&1 || true"
      ))

      print("=== Inspecting resolvconf integration ===")
      print(edge.succeed(
          "command -v resolvconf || true; "
          "ls -laR /run/resolvconf 2>&1 || true"
      ))

      print("=== Inspecting current resolver ===")
      print(edge.succeed(
          "cat /etc/resolv.conf 2>&1 || true"
      ))


      print("=== Checking DHCP DNS hook output ===")

      edge.wait_until_succeeds(
          "test -s /run/dhcpcd/resolv.conf/eth1.dhcp "
          "&& grep -q '^nameserver ' "
          "/run/dhcpcd/resolv.conf/eth1.dhcp",
          timeout=45
      )

      print(edge.succeed(
          "cat /run/dhcpcd/resolv.conf/eth1.dhcp"
      ))

      print("=== Checking DNS in native NIM ===")

      edge.wait_until_succeeds(
          """jq -e '.Ports[] | select(.IfName == "eth1") | (.DNSServers | length > 0)' /run/nim/DeviceNetworkStatus/global.json""",
          timeout=45
      )

      print("Native NIM received DHCP DNS information")


      print("=== Inspecting native NIM DPC verification ===")

      print(edge.succeed(
          "jq '{State, Testing, Ports: "
          "[.Ports[] | {IfName, DNSServers, LastError}]}' "
          "/run/nim/DeviceNetworkStatus/global.json"
      ))

      print(edge.succeed(
          "if test -s /persist/status/nim/DevicePortConfigList/global.json; "
          "then jq '{CurrentIndex, PortConfigList: "
          "[.PortConfigList[] | "
          "{Key, State, LastError, LastFailed, LastSucceeded}]}' "
          "/persist/status/nim/DevicePortConfigList/global.json; "
          "else echo 'DPC list not available'; fi"
      ))

      print(edge.succeed(
          "journalctl -u eve-zedbox --no-pager -n 250 "
          "| grep -E 'DPC verify:|controllerconn|/ping|certificate' "
          "| tail -n 35 || true"
      ))


      print("=== Waiting for NIM DPC_SUCCESS ===")

      edge.wait_until_succeeds(
          "grep -Eq '\"State\":3([,}])' "
          "/run/nim/DeviceNetworkStatus/global.json",
          timeout=90
      )

      print("Native NIM completed DPC verification")

      print("=== Verifying NIM works before zedagent starts ===")

      code, _ = edge.execute(
          "systemctl is-active --quiet eve-zedagent.service"
      )

      assert code != 0, (
          "zedagent was already active before NIM verification"
      )

      print("NIM reached DPC_SUCCESS independently of zedagent")

      print("=== Starting zedagent after NIM verification ===")

      edge.succeed("systemctl start eve-zedagent.service")
      edge.wait_for_unit("eve-zedagent.service")


      print("=== Waiting for automatic EVE onboarding ===")

      edge.wait_for_unit("eve-onboarding.path")
      edge.wait_for_unit("eve-onboarding.service")

      edge.succeed(
          "systemctl is-active --quiet eve-onboarding.service"
      )

      edge.succeed("test -s /persist/status/uuid")

      edge.succeed(
          "test -s /persist/status/zedclient/OnboardingStatus/global.json"
      )

      print("Module-managed EVE onboarding succeeded")

      print("=== Onboarding service logs ===")
      print(
          edge.succeed(
              "journalctl -u eve-onboarding.service --no-pager -n 60"
          )
      )

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
