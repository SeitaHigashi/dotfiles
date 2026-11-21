{ lib, stdenv, fetchurl }:

# Headless Orca runtime (stablyai/orca "orca-server" release asset): bundled Node 24 + orcad.
# The tarball is a prebuilt glibc bundle. It must stay byte-identical: orcad verifies
# its bundled artifacts at startup, and an autoPatchelf'd node fails with "Profile
# preflight did not run under the expected candidate runtime". So no fixup here; the
# unpatched ELF binaries run through nix-ld (programs.nix-ld.enable = true on this host).
stdenv.mkDerivation rec {
  pname = "orca-server";
  version = "1.4.268";

  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-server-linux-x64.tar.gz";
    hash = "sha256-foRwH7fgNN6NNwUMf5a2s2KJ/Q93fL7UvkcebiEwqT8=";
  };

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/share $out/bin
    cp -r . $out/share/orca-server
    # Launcher resolves its own path with readlink -f, so a symlink is fine.
    # Only orca-ide: plain `orca` would clash with the GNOME screen reader (pkgs.orca).
    ln -s $out/share/orca-server/bin/orca-ide $out/bin/orca-ide
  '';

  meta = {
    description = "Headless Orca server (orca-ide serve) for agent worktrees";
    homepage = "https://github.com/stablyai/orca";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
