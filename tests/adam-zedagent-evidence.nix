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
    name = "eve-adam-zedagent-evidence";

    # Design:
    #   nodes.controller = real Adam + test-only DHCP/DNS and certificates
    #   nodes.edge       = NixOS Edge Node configured using ../modules/
    #   testScript       = test fixtures, observations and assertions only

    # Test-only environment: two isolated NixOS VMs (NOT host services).
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

    # VM 2: NixOS Edge Node; services are provided by our modules.
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

      # Test-only compatibility configuration for upstream EVE dhcpcd.
      environment.etc."dhcpcd.conf".text = ''
        option domain_name_servers
        option domain_name
        option domain_search
        nohook resolv.conf
      '';

      environment.systemPackages = [
        pkgs.curl
        pkgs.dhcpcd
        pkgs.jq
      ];

      virtualisation.cores = 2;
    };

    # Test only: all runtime behavior remains in ../modules/.
    testScript = ''
      """Controller/Edge integration test: evidence-based report.

      The NixOS modules start the Pillar agents. This script only provisions
      an isolated test device, asks Adam to store an app configuration, and
      checks what the native zedagent actually publishes.
      """

      import json
      import re
      import shlex
      import uuid


      def stage(number, title):
          print(f"\n[REPORT] {number:02d}/08  {title}", flush=True)


      def evidence(name, value):
          print(f"[REPORT]   {name}:", flush=True)
          for line in str(value).splitlines():
              print(f"[REPORT]     {line}", flush=True)


      def evidence_json(name, value):
          print(f"[REPORT]   {name}:", flush=True)
          for line in json.dumps(value, indent=2, sort_keys=True).splitlines():
              print(f"[REPORT]     {line}", flush=True)


      # 01 — VM setup and runtime dependency checks.
      stage(1, "Two isolated NixOS VMs")
      start_all()
      controller.wait_for_unit("docker-adam.service")
      controller.wait_until_succeeds(
          "curl -kfsS --max-time 5 https://127.0.0.1:3333/ >/dev/null"
      )
      edge.wait_for_unit("multi-user.target")
      edge.wait_for_unit("eve-device-identity.service")
      edge.wait_for_unit("eve-soft-serial.service")
      edge.succeed("test -s /etc/dhcpcd.exit-hook")
      edge.succeed("! systemctl is-active --quiet eve-zedbox.service")

      adam_container = controller.succeed(
          "docker ps --filter name=adam --format '{{.Names}} {{.Image}}'"
      ).strip()
      assert "adam" in adam_container and "lfedge/adam" in adam_container

      evidence("Controller VM / Docker", adam_container)
      identity_unit = edge.succeed(
          "systemctl show eve-device-identity.service "
          "-p LoadState -p ActiveState --no-pager"
      ).strip()
      evidence("Edge VM / module-provided identity service", identity_unit)
      evidence("Before provisioning", "eve-zedbox.service is inactive (verified in Edge VM)")


      # 02 — Test credentials and Adam allowlist. Never print private keys.
      stage(2, "Adam certificates and onboarding allowlist")
      controller.succeed(
          "install -m 0644 /var/lib/adam-test/adam/ca.pem "
          "/var/lib/adam-test/config/root-certificate.pem"
      )
      cert_verification = controller.succeed(
          "openssl verify -CAfile /var/lib/adam-test/adam/ca.pem "
          "/var/lib/adam-test/adam/server.pem "
          "/var/lib/adam-test/adam/signing.pem "
          "/var/lib/adam-test/adam/encrypt.pem"
      ).strip()

      controller.succeed("install -d -m 0700 /var/lib/adam-test/onboarding-test")
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

      soft_serial = edge.succeed("cat /config/soft_serial").strip()
      assert soft_serial
      controller.succeed(
          "docker exec adam /bin/adam admin onboard add "
          "--path /adam/run/onboarding-test/nixos-edge-test.pem "
          "--serial " + shlex.quote(soft_serial) + " "
          "--server https://127.0.0.1:3333 "
          "--server-ca /adam/run/adam/server.pem"
      )
      evidence("openssl verify / Controller VM", cert_verification)
      evidence("Soft Serial / Edge VM", soft_serial)
      allowlist_output = controller.succeed(
          "docker exec adam /bin/adam admin onboard list "
          "--server https://127.0.0.1:3333 "
          "--server-ca /adam/run/adam/server.pem"
      ).strip()
      evidence("Adam onboarding allowlist / CLI", allowlist_output)


      # 03 — Test-only provisioning: modules do not embed credentials.
      stage(3, "Provision credentials into the Edge VM")
      shared = "/tmp/shared/eve-onboard-test"
      controller.succeed("install -d -m 0700 " + shared)
      credentials = [
          ("onboard.cert.pem", "/var/lib/adam-test/onboarding-test/nixos-edge-test.pem", "0644"),
          ("onboard.key.pem", "/var/lib/adam-test/onboarding-test/nixos-edge-test-key.pem", "0600"),
          ("root-certificate.pem", "/var/lib/adam-test/config/root-certificate.pem", "0644"),
      ]
      for name, source, mode in credentials:
          controller.succeed(f"install -m {mode} {source} {shared}/{name}")
          edge.succeed(f"install -m {mode} {shared}/{name} /config/{name}")
      controller.succeed(
          "rm -f " + " ".join(shared + "/" + name for name, _, _ in credentials)
      )
      edge.succeed('test "$(stat -c %a /config/onboard.key.pem)" = 600')
      edge.succeed("test -s /config/root-certificate.pem")
      edge.succeed("install -m 0600 /dev/null /config/onboarding.ready")
      evidence("Trigger / Edge VM", "/config/onboarding.ready (created after credentials)")
      evidence("Onboard private key", "mode 600 (checked; key content not printed)")


      # 04 — Inspect network state published by the real NIM.
      stage(4, "Virtual LAN, DHCP/DNS and NIM verification")
      edge.wait_for_unit("eve-nim.service")
      edge.wait_until_succeeds(
          "jq -e '.State == 3' /run/nim/DeviceNetworkStatus/global.json >/dev/null",
          timeout=120,
      )
      edge.wait_until_succeeds(
          "jq -e '.Ports[] | select(.IfName == \"eth1\") | "
          "(.DNSServers | length > 0)' /run/nim/DeviceNetworkStatus/global.json >/dev/null",
          timeout=60,
      )
      edge.wait_until_succeeds(
          "test -s /run/dhcpcd/resolv.conf/eth1.dhcp", timeout=45
      )

      edge_address = edge.succeed("ip -4 -o addr show dev eth1").strip()
      controller_address = controller.succeed("ip -4 -o addr show dev eth1").strip()
      def ipv4(text):
          match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", text)
          assert match, f"No IPv4 address in: {text}"
          return match.group(1)

      controller_ip = ipv4(controller_address)
      edge_ip = ipv4(edge_address)
      assert controller_ip == "192.168.1.1"
      assert edge_ip.startswith("192.168.1.") and edge_ip != controller_ip
      resolved = edge.succeed("getent ahostsv4 controller").split()[0]
      assert resolved == controller_ip

      edge.wait_until_succeeds(
          "curl --cacert /config/root-certificate.pem -fsS --max-time 5 "
          "https://controller:3333/ >/dev/null",
          timeout=90,
      )
      network = json.loads(edge.succeed("cat /run/nim/DeviceNetworkStatus/global.json"))
      assert network["State"] == 3
      eth1_ports = [p for p in network["Ports"] if p.get("IfName") == "eth1"]
      assert eth1_ports and eth1_ports[0].get("DNSServers")
      dhcp_dns = edge.succeed("cat /run/dhcpcd/resolv.conf/eth1.dhcp").strip()

      evidence("Controller / ip -4 addr show eth1", controller_address)
      evidence("Edge / ip -4 addr show eth1", edge_address)
      evidence("DNS controller / Edge VM", resolved)
      evidence("DHCP DNS / Edge VM", dhcp_dns)
      evidence_json(
          "DeviceNetworkStatus (from native NIM)",
          {"State": network["State"], "Ports": [
              {"IfName": p.get("IfName"), "DNSServers": p.get("DNSServers")}
              for p in eth1_ports
          ]},
      )
      evidence("HTTPS from Edge VM", "https://controller:3333/ (verified with test CA)")


      # 05 — Systemd units are module-provided; runtime publications are native.
      stage(5, "Onboarding and native agent startup")
      units = [
          "eve-zedbox.service", "eve-nim.service", "eve-onboarding.service",
          "eve-tpmmgr.service", "eve-zedagent.service",
          "eve-nodeagent.service", "eve-baseosmgr.service",
      ]
      service_states = {}
      for unit in units:
          edge.wait_for_unit(unit)
          state = edge.succeed("systemctl is-active " + unit).strip()
          assert state == "active", f"{unit} is {state}"
          service_states[unit] = state
      edge.succeed("test -s /persist/status/uuid")
      edge.succeed("test -s /persist/status/zedclient/OnboardingStatus/global.json")
      edge.wait_until_succeeds(
          "test -s /run/nodeagent/NodeAgentStatus/nodeagent.json", timeout=60
      )
      edge.wait_until_succeeds("test -S /run/baseosmgr/ZbootStatus.sock", timeout=60)
      edge_uuid = edge.succeed("cat /persist/status/uuid").strip().lower()
      onboarding_status = json.loads(edge.succeed(
          "cat /persist/status/zedclient/OnboardingStatus/global.json"
      ))
      evidence("Device UUID / Edge VM", edge_uuid)
      evidence_json("OnboardingStatus (native publication)", onboarding_status)
      evidence_json("systemd / Edge VM", service_states)
      evidence("NodeAgent publication", "/run/nodeagent/NodeAgentStatus/nodeagent.json")
      evidence("BaseOSMgr socket", "/run/baseosmgr/ZbootStatus.sock")


      # 06 — Observe HTTP request from Adam's actual Docker logs.
      stage(6, "zedagent requests configuration from Adam")
      controller.wait_until_succeeds(
          "docker logs adam 2>&1 | grep -E "
          "'requested /api/v2/edgedevice/id/[0-9a-f-]+/config'",
          timeout=90,
      )
      log_lines = controller.succeed("docker logs adam 2>&1").splitlines()
      pattern = re.compile(
          r"/api/v2/edgedevice/id/"
          r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/config"
      )
      requests = []
      found_uuids = set()

      for line in log_lines:
          if "requested " not in line:
              continue

          match = pattern.search(line)
          if match is not None:
              requests.append(line)
              found_uuids.add(match.group(1))
      assert len(found_uuids) == 1, found_uuids
      device_uuid = found_uuids.pop()
      assert device_uuid == edge_uuid, f"Adam: {device_uuid}, Edge: {edge_uuid}"
      evidence("Adam Docker log / GET config", requests[-1])
      evidence("Device UUID comparison", f"Adam = Edge = {device_uuid}")


      # 07 — Supply a minimal config via the real Adam administration API.
      stage(7, "Adam stores the test EdgeDevConfig")
      app_uuid = str(uuid.uuid4())
      app_name = "nixos-zedagent-app-test"
      requested_config = {
          "id": {"uuid": device_uuid, "version": "1"},
          "apps": [{
              "uuidandversion": {"uuid": app_uuid, "version": "1"},
              "displayname": app_name,
              "activate": False,
              "fixedresources": {
                  "vcpus": 1, "maxcpus": 1, "memory": 262144, "maxmem": 262144,
              },
          }],
      }
      admin_cli = (
          "docker exec adam /bin/adam admin "
          "--server https://127.0.0.1:3333 "
          "--server-ca /adam/run/adam/server.pem"
      )
      set_cli = admin_cli.replace("docker exec adam ", "docker exec -i adam ", 1)
      controller.succeed(
          "printf '%s' " + shlex.quote(json.dumps(requested_config)) + " | "
          + set_cli + " device config set --uuid " + shlex.quote(device_uuid)
          + " --config-path -"
      )
      get_output = controller.succeed(
          admin_cli + " device config get --uuid " + shlex.quote(device_uuid)
      )
      stored_config = json.loads(next(
          line for line in get_output.splitlines() if line.lstrip().startswith("{")
      ))
      assert stored_config["id"]["uuid"] == device_uuid
      assert stored_config["apps"][0]["uuidandversion"]["uuid"] == app_uuid
      evidence("Source / Controller VM", "adam admin device config get --uuid " + device_uuid)
      evidence_json("EdgeDevConfig returned by Adam", stored_config)


      # 08 — Read native zedagent PubSub, corroborate with upstream log.
      stage(8, "zedagent publishes AppInstanceConfig")
      app_path = f"/run/zedagent/AppInstanceConfig/{app_uuid}.json"
      edge.wait_until_succeeds("test -s " + shlex.quote(app_path), timeout=180)
      published = json.loads(edge.succeed("cat " + shlex.quote(app_path)))
      assert published["UUIDandVersion"]["UUID"].lower() == app_uuid
      assert published["DisplayName"] == app_name
      assert published["Activate"] is False
      assert published["FixedResources"]["Memory"] == 262144
      assert not published.get("Errors"), published.get("Errors")

      # Also check a native log event. A generated JSON file alone would be weaker proof.
      edge.wait_until_succeeds(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -F 'App instance config create' "
          "| grep -F " + shlex.quote(app_uuid),
          timeout=30,
      )
      agent_log = edge.succeed(
          "journalctl -u eve-zedbox --no-pager -o cat "
          "| grep -F 'App instance config create' "
          "| grep -F " + shlex.quote(app_uuid) + " | tail -n 1"
      ).strip()
      try:
          log_entry = json.loads(agent_log)
          agent_event = {
              "time": log_entry.get("time"),
              "source": log_entry.get("source"),
              "msg": log_entry.get("msg"),
              "obj_uuid": log_entry.get("obj_uuid"),
          }
      except json.JSONDecodeError:
          agent_event = agent_log

      stored_app = stored_config["apps"][0]
      checks = {
          "Application UUID": (
              stored_app["uuidandversion"]["uuid"],
              published["UUIDandVersion"]["UUID"].lower(),
          ),
          "Display name": (stored_app["displayname"], published["DisplayName"]),
          "Activate": (stored_app.get("activate", False), published["Activate"]),
          "Memory": (stored_app["fixedresources"]["memory"],
                     published["FixedResources"]["Memory"]),
          "vCPUs": (stored_app["fixedresources"]["vcpus"],
                    published["FixedResources"]["VCpus"]),
      }
      for name, (adam_value, pubsub_value) in checks.items():
          assert adam_value == pubsub_value, f"{name}: {adam_value} != {pubsub_value}"
      edge.succeed("systemctl is-active --quiet eve-zedbox.service")

      # Display selected real fields rather than a second wall of JSON.
      request_log = controller.succeed("docker logs adam 2>&1").splitlines()
      later_requests = [
          line for line in request_log
          if "requested " in line and f"/id/{device_uuid}/config" in line
      ]
      assert len(later_requests) > len(requests), (
          "Adam did not log a further config request after the update"
      )
      evidence("Adam GET after device config was set", later_requests[-1])
      evidence("Source / Edge VM", app_path)
      evidence_json("AppInstanceConfig (selected fields from native PubSub)", {
          "UUIDandVersion": published["UUIDandVersion"],
          "DisplayName": published["DisplayName"],
          "Activate": published["Activate"],
          "FixedResources": {
              "VCpus": published["FixedResources"]["VCpus"],
              "MaxCpus": published["FixedResources"]["MaxCpus"],
              "Memory": published["FixedResources"]["Memory"],
              "MaxMem": published["FixedResources"]["MaxMem"],
          },
          "Errors": published.get("Errors"),
      })
      evidence_json("Native zedagent creation event", agent_event)
      print("[FULL-JSON] Edge VM AppInstanceConfig (unfiltered):", flush=True)
      print(json.dumps(published, indent=2, sort_keys=True), flush=True)
      for name, (adam_value, pubsub_value) in checks.items():
          evidence("Checked: " + name, f"Adam={adam_value!r}; PubSub={pubsub_value!r}")

      print("\n[REPORT] RESULT: Adam configuration and native AppInstanceConfig match", flush=True)
      print("[REPORT] LIMIT: Activate=false; VM deployment is not part of this test", flush=True)
    '';
  }
