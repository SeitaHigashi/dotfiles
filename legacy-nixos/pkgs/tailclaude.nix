{ lib, buildNpmPackage, fetchFromGitHub }:

buildNpmPackage rec {
  pname = "tailclaude";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "rohitg00";
    repo = "tailclaude";
    rev = "cac0bdf7a581b01eeba86860a6de58a08a4a8a11";
    hash = "sha256-53UCwBEmoVHfThQnxLBWMEOb84HvexK9dCXTbMi67TE=";
  };

  npmDepsHash = "sha256-9uRm538SxA2Gz9KoNetCjHPBWFMjV+Whjv55zW6XOz4=";

  # TypeScript is executed directly via tsx — no separate build step
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/tailclaude
    cp -r src $out/lib/tailclaude/
    cp -r node_modules $out/lib/tailclaude/
    cp package.json $out/lib/tailclaude/
    runHook postInstall
  '';

  meta = {
    description = "Claude Code web interface via Tailscale";
    homepage = "https://github.com/rohitg00/tailclaude";
  };
}
