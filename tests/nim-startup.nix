{pkgs ? import <nixpkgs> {}}:
pkgs.testers.runNixOSTest {
  name = "eve-nim-startup";

  nodes.machine = {pkgs, ...}: {
    imports = [
      ../modules/edge-node.nix
    ];

    services.eve-edge.enable = true;
    services.eve-edge.nim.enable = true;

    virtualisation.memorySize = 2048;

    environment.systemPackages = with pkgs; [
      iproute2
    ];

    system.stateVersion = "25.11";
  };

  testScript = ''
    start_all()

    machine.wait_for_unit("multi-user.target")

    print("=== Checking zedbox and zedagent ===")

    machine.wait_for_unit("eve-zedbox.service")
    machine.wait_for_unit("eve-zedagent.service")

    machine.succeed(
        "systemctl is-active --quiet eve-zedbox.service"
    )

    machine.wait_for_file("/run/zedagent.pid")

    print("=== Checking native NIM startup ===")

    machine.wait_for_unit("eve-nim.service")

    machine.succeed(
        "systemctl is-active --quiet eve-nim.service"
    )

    machine.wait_for_file("/run/nim.pid")

    print("=== Checking NIM PubSub initialization ===")

    machine.wait_until_succeeds(
        "test -S /run/nim/DeviceNetworkStatus.sock",
        timeout=60
    )


    print("=== Checking published DeviceNetworkStatus ===")

    machine.wait_until_succeeds(
        "test -s /run/nim/DeviceNetworkStatus/global.json",
        timeout=60
    )

    print(
        machine.succeed(
            "cat /run/nim/DeviceNetworkStatus/global.json"
        )
    )

    import json

    status = json.loads(
        machine.succeed(
            "cat /run/nim/DeviceNetworkStatus/global.json"
        )
    )

    ports = status.get("Ports")

    assert isinstance(ports, list) and len(ports) > 0, (
        "NIM did not publish any network ports"
    )

    assert all(
        isinstance(port.get("IfName"), str) and port["IfName"]
        for port in ports
    ), "NIM published an invalid interface name"

    print(f"NIM published {len(ports)} network port(s)")


    machine.wait_until_succeeds(
        "journalctl -u eve-zedbox.service --no-pager -o cat | grep -Fq 'Starting nim'",
        timeout=60
    )

    machine.succeed(
        "systemctl is-active --quiet eve-zedbox.service"
    )

    machine.succeed("test ! -f /run/nim.done")

    print("=== NIM diagnostic information ===")

    print(machine.succeed("ip -br addr"))

    print(
        machine.succeed(
            "journalctl -u eve-zedbox.service -n 40 --no-pager -o cat"
        )
    )

    print("Native NIM startup verified")
  '';
}
