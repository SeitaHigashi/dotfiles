{ lib, stdenv, fetchurl, autoPatchelfHook, libcap_ng }:

let
  iiiBin = fetchurl {
    url = "https://github.com/iii-hq/iii/releases/download/iii/v0.11.3/iii-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-0a7nvEoPi6Yyvw71duN7rQIa5W4SedEA5qIVgURtF6Y=";
  };

  iiiWorkerBin = fetchurl {
    url = "https://github.com/iii-hq/iii/releases/download/iii/v0.11.3/iii-worker-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-z2as3Ifd/MMpaSYd/zj27hBYPfBronIyi+uRmuKr0pY=";
  };
in

stdenv.mkDerivation {
  pname = "iii";
  version = "0.11.3";

  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ libcap_ng stdenv.cc.cc.lib ];

  installPhase = ''
    mkdir -p $out/bin
    tar -xf ${iiiBin} iii
    cp iii $out/bin/iii
    chmod +x $out/bin/iii
    tar -xf ${iiiWorkerBin} iii-worker
    cp iii-worker $out/bin/iii-worker
    chmod +x $out/bin/iii-worker
  '';

  meta = {
    description = "iii engine runtime for TailClaude";
    homepage = "https://github.com/iii-hq/iii";
    platforms = [ "x86_64-linux" ];
  };
}
