{ pkgs ? import <nixpkgs> {} }:
let
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
