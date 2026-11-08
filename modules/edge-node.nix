{lib, ...}: {
  imports = [
    ./release-metadata.nix
    ./zedagent.nix
    ./nim.nix
    ./nodeagent.nix
    ./baseosmgr.nix
    ./onboarding.nix
    ./controller-config.nix
    ./device-identity.nix
    ./tpmmgr.nix
    ./controller-trust.nix
    ./soft-serial.nix
  ];

  options.services.eve-edge.enable =
    lib.mkEnableOption "EVE-like edge node";
}
