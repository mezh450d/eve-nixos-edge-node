{pkgs ? import <nixpkgs> {}}: let
  version = "17.4.0";
  eve_os = pkgs.fetchFromGitHub {
    owner = "lf-edge";
    repo = "eve";
    rev = "${version}";
    hash = "sha256-o7Lpq6vbgWWVMVlK+cpx42fFaGuFrbjs7FTorukiqGY=";
  };
  zfs = pkgs.zfs;
in
  pkgs.buildGoModule {
    pname = "pillar";
    version = version;
    src = "${eve_os}/pkg/pillar";

    postPatch = ''
      cp ${./patches/nodeagent-nixos-zboot.go} \
        cmd/nodeagent/nixos_zboot.go

      substituteInPlace cmd/nodeagent/nodeagent.go \
        --replace-fail \
        'nodeagentCtx.zboot = realZboot{}' \
        'nodeagentCtx.zboot = selectNodeagentZboot()'

      cp ${./patches/baseosmgr-nixos-zboot.go} \
        cmd/baseosmgr/nixos_zboot.go

      # NixOS has no EVE A/B upgrade partition.
      # Keep native nettrace behavior, but skip the EVE-specific OTA check.
      substituteInPlace cmd/zedagent/handleconfig.go \
        --replace-fail \
        'if zboot.IsCurrentPartitionStateInProgress() && lastNetdumpAge > uptime {' \
        'if os.Getenv("EVE_NODEAGENT_BOOT_BACKEND") != "nixos" && zboot.IsCurrentPartitionStateInProgress() && lastNetdumpAge > uptime {'

      substituteInPlace cmd/baseosmgr/baseosmgr.go \
        --replace-fail \
        '&realZboot{log: logArg}' \
        'selectBaseosmgrZboot(&realZboot{log: logArg})'
    '';

    vendorHash = null;

    nativeBuildInputs = with pkgs; [
      pkg-config
    ];

    buildInputs = with pkgs; [
      zfs
      libtirpc
      util-linux
      openssl
      zlib
      pam
    ];

    # go-libzfs normally expects:
    # /usr/include/libzfs
    # /usr/include/libspl
    #
    # On NixOS these headers are inside the Nix store.
    CGO_CFLAGS = ''
      -I${zfs.dev}/include/libzfs
      -I${zfs.dev}/include/libspl
    '';

    CGO_LDFLAGS = ''
      -L${zfs}/lib
    '';

    doCheck = false;
  }
