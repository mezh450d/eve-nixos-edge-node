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

      systemd.services.eve-nim.unitConfig.ConditionPathExists = "/config/onboard.cert.pem";

      services.eve-edge = {
        enable = true;
        nim.enable = true;
        nim.dhcpDnsHook.enable = true;
        onboarding.enable = true;
        nodeagent.enable = true;
        baseosmgr.enable = true;
        tpmmgr.enable = true;
        tpmmgr.softwareCertificates.enable = true;
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
      import json
      import re
      import uuid

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

      print("=== Checking native NodeAgent module integration ===")

      edge.succeed(
          "systemctl cat eve-nodeagent.service >/dev/null"
      )

      edge.succeed(
          "test -x /run/current-system/sw/bin/nodeagent"
      )

      edge.succeed(
          "! systemctl is-active --quiet eve-nodeagent.service"
      )

      print("Native NodeAgent unit is available but not started")

      print("=== Verifying module-managed zedbox startup ===")
      edge.wait_for_unit("eve-zedbox.service")
      edge.succeed("systemctl is-active --quiet eve-zedbox.service")
      print("Native zedbox started through systemd dependencies")

      print("=== Verifying module-managed NIM startup ===")
      edge.wait_for_unit("eve-nim.service")
      edge.succeed("systemctl is-active --quiet eve-nim.service")

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

      print("=== Verifying NIM readiness with automatic agent startup ===")

      edge.succeed(
          "jq -e '.State == 3' "
          "/run/nim/DeviceNetworkStatus/global.json >/dev/null"
      )

      print("NIM reached DPC_SUCCESS with module-managed agent startup")

      print("=== Verifying release metadata provided by NixOS Module ===")

      edge.succeed("test -s /run/eve-release")
      edge.succeed("grep -q '^NixOS-' /run/eve-release")

      print(edge.succeed("cat /run/eve-release"))

      print("=== Verifying module-managed tpmmgr startup ===")

      edge.wait_for_unit("eve-soft-certs.service")
      edge.wait_for_unit("eve-tpmmgr.service")

      edge.succeed("systemctl is-active --quiet eve-tpmmgr.service")

      print("=== Verifying module-managed software certificates ===")

      edge.succeed("systemctl is-active --quiet eve-soft-certs.service")

      edge.succeed("test -s /persist/certs/ecdh.cert.pem")
      edge.succeed("test -s /persist/certs/ecdh.key.pem")

      edge.succeed("test -s /persist/certs/attest.cert.pem")
      edge.succeed("test -s /persist/certs/attest.key.pem")

      print("Native software certificates and tpmmgr verified")

      print("=== Verifying module-managed zedagent startup ===")

      edge.wait_for_unit("eve-zedagent.service")

      edge.succeed("systemctl is-active --quiet eve-zedagent.service")

      print("Native zedagent started through systemd dependencies")


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

      print("=== Starting native NodeAgent on NixOS ===")

      edge.succeed("systemctl start eve-nodeagent.service")

      edge.wait_for_unit("eve-nodeagent.service")

      print("=== Waiting for native NodeAgentStatus ===")

      edge.wait_until_succeeds(
          "test -s /run/nodeagent/NodeAgentStatus/nodeagent.json",
          timeout=45,
      )

      print("Native NodeAgentStatus was published")

      print(
          edge.succeed(
              "cat /run/nodeagent/NodeAgentStatus/nodeagent.json"
          )
      )

      print("=== Verifying native zedagent received NodeAgentStatus ===")

      edge.wait_until_succeeds(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -F '\"source\":\"zedagent\"' "
          "| grep -F '\"msg\":\"Nodeagent status create\"'",
          timeout=30,
      )

      print("Native zedagent consumed NodeAgentStatus successfully")

      print("=== Checking native baseosmgr integration ===")

      edge.succeed(
          "systemctl cat eve-baseosmgr.service >/dev/null"
      )

      edge.succeed(
          "test -x /run/current-system/sw/bin/baseosmgr"
      )

      edge.succeed(
          "! systemctl is-active --quiet eve-baseosmgr.service"
      )

      print("=== Starting native baseosmgr ===")

      edge.succeed("systemctl start eve-baseosmgr.service")
      edge.wait_for_unit("eve-baseosmgr.service")

      print("=== Waiting for native ZbootStatus publication ===")

      edge.wait_until_succeeds(
          "test -S /run/baseosmgr/ZbootStatus.sock",
          timeout=30,
      )

      print("Native baseosmgr ZbootStatus publication is available")

      print("=== Waiting for native tpmmgr AttestQuote ===")

      edge.wait_until_succeeds(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -F '\"source\":\"tpmmgr\"' "
          "| grep -F '\"msg\":\"Attest quote create\"'",
          timeout=90,
      )

      print("SUCCESS: Native tpmmgr published AttestQuote")

      print("=== Inspecting baseosmgr and zedagent initialization ===")

      code, output = edge.execute(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -Ei 'baseosmgr|Zboot reported restarted|"
          "configTimerTask|getLatestConfig' "
          "| tail -n 60"
      )

      print(output)

      print("=== Inspecting native Adam device configuration CLI ===")

      for command in [
          "docker exec adam adam admin device config --help",
          "docker exec adam adam admin device config get --help",
          "docker exec adam adam admin device config set --help",
          "docker exec adam adam admin device list --help",
      ]:
          code, output = controller.execute(command + " 2>&1")
          print(f"Command: {command}, exit code: {code}")
          print(output[:6000])

      print("=== Verifying native Adam Config Fetch ===")

      print("=== Checking running Controller containers ===")

      code, output = controller.execute(
          "docker ps --format '{{.ID}} {{.Names}}'"
      )
      print(output)

      controller.wait_until_succeeds(
          "docker ps -q "
          "| xargs -r -n1 docker logs --tail 1000 2>&1 "
          "| grep -E 'requested /api/v2/edgedevice/id/[0-9a-f-]+/config'",
          timeout=45,
      )

      print("Native zedagent successfully requested config from Adam")

      code, output = controller.execute(
          "docker ps -q "
          "| xargs -r -n1 docker logs --tail 1000 2>&1 "
          "| grep -E 'requested /api/v2/edgedevice/id/.*/config|"
          "config not found for device' "
          "| tail -n 15"
      )

      print(output)

      print("=== Checking Adam management API connectivity ===")

      # Use the same endpoint and TLS certificate as the working onboarding CLI.
      adam_cli = (
          "docker exec adam /bin/adam admin "
          "--server https://127.0.0.1:3333 "
          "--server-ca /adam/run/adam/server.pem"
      )

      status, output = controller.execute(
          f"{adam_cli} device list 2>&1"
      )

      print(output)

      assert status == 0, (
          "Adam management CLI could not connect:\n" + output
      )

      print("Adam management API is reachable")

      print("=== Identifying dynamically onboarded device ===")

      adam_logs = controller.succeed("docker logs adam 2>&1")

      device_uuids = sorted(
          set(
              re.findall(
                  r"/api/v2/edgedevice/id/"
                  r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})"
                  r"/config",
                  adam_logs,
              )
          )
      )

      assert len(device_uuids) == 1, (
          f"Expected one onboarded test device, found: {device_uuids}"
      )

      device_uuid = device_uuids[0]

      print("Onboarded device UUID:", device_uuid)

      print("=== Preparing minimal native EdgeDevConfig ===")

      app_uuid = str(uuid.uuid4())
      app_name = "nixos-zedagent-app-test"

      config_data = {
          "id": {
              "uuid": device_uuid,
              "version": "1",
          },
          "apps": [
              {
                  "uuidandversion": {
                      "uuid": app_uuid,
                      "version": "1",
                  },
                  "displayname": app_name,
                  "activate": False,
                  "fixedresources": {
                      "vcpus": 1,
                      "maxcpus": 1,
                      "memory": 262144,
                      "maxmem": 262144,
                  },
              }
          ],
      }

      config_json = json.dumps(config_data)

      print(config_json)

      print("=== Uploading EdgeDevConfig through native Adam CLI ===")

      set_command = (
          "printf '%s' "
          + shlex.quote(config_json)
          + " | "
          + adam_cli.replace(
              "docker exec adam ",
              "docker exec -i adam ",
              1,
          )
          + " device config set "
          + "--uuid "
          + shlex.quote(device_uuid)
          + " --config-path -"
      )

      code, output = controller.execute(set_command + " 2>&1")

      print("Set config exit code:", code)
      print(output)

      assert code == 0, "Adam rejected the device configuration"

      print("=== Reading configuration back from Adam ===")

      get_command = (
          adam_cli
          + " device config get --uuid "
          + shlex.quote(device_uuid)
      )

      code, output = controller.execute(get_command + " 2>&1")

      print(output)

      assert code == 0, "Could not read configuration back from Adam"

      stored_config = json.loads(
          next(line for line in output.splitlines() if line.lstrip().startswith("{"))
      )

      assert stored_config["id"]["uuid"] == device_uuid, (
          "Adam returned a configuration for the wrong device"
      )

      print("Native Adam configuration provisioning succeeded")

      print("=== Waiting for native AppInstanceConfig publication ===")

      app_config_path = (
          f"/run/zedagent/AppInstanceConfig/{app_uuid}.json"
      )

      edge.wait_until_succeeds(
          f"test -s {app_config_path}",
          timeout=180,
      )

      print("=== Native AppInstanceConfig was published ===")

      published_config = edge.succeed(
          f"cat {app_config_path}"
      )

      print(published_config)

      app_config = json.loads(published_config)

      assert app_config["UUIDandVersion"]["UUID"].lower() == app_uuid
      assert app_config["DisplayName"] == app_name
      assert app_config["Activate"] is False
      assert not app_config.get("Errors"), app_config.get("Errors")

      print("SUCCESS: Native zedagent published AppInstanceConfig")

      print("=== Diagnosing zedagent after onboarding ===")

      import time

      time.sleep(45)

      print("=== Inspecting received device configuration ===")

      code, output = edge.execute(
          "ls -l /persist/checkpoint/lastconfig "
          "/persist/checkpoint/lastconfig.bak 2>&1"
      )

      print(output)

      code, output = edge.execute(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -Ei "
          "'ConfigGetStatus|parseConfig|config received|"
          "config processing|publishAppInstanceConfig' "
          "| tail -n 50"
      )

      print(output)

      print("=== Verifying zedbox remains running ===")

      edge.succeed(
          "systemctl is-active --quiet eve-zedbox.service"
      )

      print("Native EVE agents are still running")

      print("=== Checking required Pillar publications ===")

      required_status = [
          "/persist/status/zedclient/OnboardingStatus/global.json",
          "/run/nim/DeviceNetworkStatus/global.json",
          "/run/nodeagent/NodeAgentStatus/nodeagent.json",
      ]

      for path in required_status:
          code, _ = edge.execute("test -s " + path)
          result = "present" if code == 0 else "missing"
          print(f"{path}: {result}")

      print("=== Checking native baseosmgr ZbootStatus publication ===")

      code, output = edge.execute(
          "if test -d /run/baseosmgr/ZbootStatus; then "
          "find /run/baseosmgr/ZbootStatus "
          "-maxdepth 1 -type f -name '*.json' -print; "
          "else echo 'baseosmgr ZbootStatus is not available'; fi"
      )

      print(output)

      print("=== zedagent initialization and config logs ===")

      code, output = edge.execute(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -Ei "
          "'NodeAgentStatus|ZbootStatus|configTimerTask|"
          "getLatestConfig|requestConfigByURL|"
          "lookupControllerCert|PublishDeviceInfo' "
          "| tail -n 70"
      )

      print(output)

      print("=== Adam configuration requests ===")

      code, output = controller.execute(
          "docker logs adam 2>&1 "
          "| grep -E '/api/v2/edgedevice/id/[0-9a-f-]+/config' "
          "| tail -n 20"
      )

      print(output if output.strip() else "No config requests found in Adam logs")

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
