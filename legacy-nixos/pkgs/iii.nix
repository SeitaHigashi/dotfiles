{ lib, stdenv, fetchurl }:

stdenv.mkDerivation rec {
  pname = "iii";
  version = "0.10.0";

  src = fetchurl {
    url = "https://github.com/iii-hq/iii/releases/download/iii/v${version}/iii-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-kb54njyXlpPjM9q9dwz1OoqMnV/+Duow/kbPimcSxPM=";
  };

  dontBuild = true;
  dontFixup = true;

  unpackPhase = ''
    tar -xf $src
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp iii $out/bin/iii
    chmod +x $out/bin/iii
  '';

  meta = {
    description = "iii engine runtime for TailClaude";
    homepage = "https://github.com/iii-hq/iii";
    platforms = [ "x86_64-linux" ];
  };
}
