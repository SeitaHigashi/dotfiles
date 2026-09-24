{ config, lib, pkgs, ... }:

##############################################################################
# Multica (AI coding-agent management workspace), self-hosted: official
# docker-compose.selfhost.yml (Next.js + Go backend + PostgreSQL/pgvector)
# ported to podman, 3 containers, same pattern as Minecraft (ftb-evolution.nix).
#
# Docs:
#   docs/services/multica.md   what it is, access, secrets, known limitations
#   docs/runbooks/multica.md   image update, secret rotation
#   docs/network.md            why Multica gets two Tailscale Serve ports
#   docs/decisions/2026-08-18-multica-github-app-key-podman-secret.md
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  # Container-internal listen ports (fixed by the official images).
  backendContainerPort = 8080;
  frontendContainerPort = 3000;

  # Host-side (127.0.0.1) publish ports. Shifted from the containers'
  # defaults because 3000/8080 are already taken by Grafana/Open WebUI.
  # backend is also published for multica-cli's daemon, which can't go
  # through the frontend's SSR proxy — see docs/network.md.
  frontendHostPort = 3001;
  backendHostPort = 8082;

  secretsFile = config.age.secrets.multica-env.path;
  githubAppKeyFile = config.age.secrets.multica-github-app-key.path;
  githubAppKeySecretName = "multica-github-app-key";
in
{
  age.secrets.multica-env = {
    file = ../secrets/multica-env.age;
    mode = "0400";
  };

  # GITHUB_APP_PRIVATE_KEY (multi-line PEM) is a separate age secret,
  # injected via a podman secret rather than environmentFiles — the latter's
  # KEY=VALUE parser can't hold a multi-line value. Details:
  # docs/decisions/2026-08-18-multica-github-app-key-podman-secret.md.
  age.secrets.multica-github-app-key = {
    file = ../secrets/multica-github-app-key.age;
    mode = "0400";
  };

  # Registers the PEM above as a podman secret (idempotent via --replace).
  # Must complete before multica-backend starts.
  systemd.services.multica-github-secret = {
    description = "Register Multica GitHub App private key as a podman secret";
    before = [ "podman-multica-backend.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.podman}/bin/podman secret create --replace ${githubAppKeySecretName} ${githubAppKeyFile}";
    };
  };

  systemd.services.podman-multica-backend = {
    after = [ "multica-github-secret.service" ];
    requires = [ "multica-github-secret.service" ];
  };

  virtualisation.oci-containers.containers = {
    multica-postgres = {
      image = "docker.io/pgvector/pgvector:pg17";
      environment = {
        POSTGRES_DB = "multica";
        POSTGRES_USER = "multica";
      };
      environmentFiles = [ secretsFile ]; # POSTGRES_PASSWORD
      volumes = [ "multica-pgdata:/var/lib/postgresql/data" ];
      autoStart = true;
    };

    multica-backend = {
      image = "ghcr.io/multica-ai/multica-backend:latest";
      dependsOn = [ "multica-postgres" ];
      # frontend reaches this by container name (multica-backend:8080) over
      # podman's default network; this publish is for multica-cli's
      # daemon/runtime (docs/network.md).
      ports = [ "127.0.0.1:${toString backendHostPort}:${toString backendContainerPort}" ];
      volumes = [ "multica-backend-uploads:/app/data/uploads" ];
      environment = {
        PORT = toString backendContainerPort;
        APP_ENV = "production";
        ALLOW_SIGNUP = "true";
        # Self-host-only feature (Forgejo/Gitea/GitLab integration); key in secretsFile.
        MULTICA_VCS_INTEGRATION_ENABLED = "true";
        # FRONTEND_ORIGIN / CORS_ALLOWED_ORIGINS / MULTICA_APP_URL /
        # MULTICA_PUBLIC_URL depend on the Tailscale Serve URL, so they're set
        # in modules/reverse-proxy.nix's Multica section instead (same
        # placement rule as Grafana's root_url / n8n's webhookUrl).
      };
      # DATABASE_URL / JWT_SECRET / MULTICA_VCS_SECRET_KEY.
      # GITHUB_APP_PRIVATE_KEY is NOT here (can't hold newlines) — see
      # the podman secret above and docs/decisions/2026-08-18-multica-github-app-key-podman-secret.md.
      environmentFiles = [ secretsFile ];
      extraOptions = [ "--secret=${githubAppKeySecretName},type=env,target=GITHUB_APP_PRIVATE_KEY" ];
      autoStart = true;
    };

    multica-frontend = {
      image = "ghcr.io/multica-ai/multica-web:latest";
      dependsOn = [ "multica-backend" ];
      # Host side only: 3001. Container-internal stays 3000; inter-container
      # traffic uses the internal port regardless.
      ports = [ "127.0.0.1:${toString frontendHostPort}:${toString frontendContainerPort}" ];
      environment = {
        HOSTNAME = "0.0.0.0";
        REMOTE_API_URL = "http://multica-backend:${toString backendContainerPort}";
      };
      autoStart = true;
    };
  };

  ############################################################################
  # multica daemon (local agent runtime). Runs claude/opencode outside the
  # containers above; systemd-managed since 2026-08-12 (was a manual
  # `multica daemon start`, which died on every reboot).
  # ~/.multica/config.json (login token) is out of repo scope — created by
  # `multica setup`/`multica login`, not agenix'd. Details: docs/services/multica.md.
  ############################################################################
  systemd.services.multica-daemon = {
    description = "Multica local agent runtime daemon";
    after = [ "network-online.target" "podman-multica-backend.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/${m.userName}";
      # Agent subprocesses need both multica-cli's own bin dir and
      # opencode's (/run/current-system/sw/bin) on PATH — neither is in a
      # systemd unit's default PATH. ~/.nix-profile is an imperative install
      # (nix profile install), so it can vanish out from under this on GC.
      PATH = lib.mkForce "/home/${m.userName}/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin";
    };
    serviceConfig = {
      Type = "simple";
      User = m.userName;
      # --foreground required: without it multica double-forks and systemd
      # loses the process (can't manage restarts).
      ExecStart = "${pkgs.unstable.multica-cli}/bin/multica daemon start --foreground";
      Restart = "always";
      RestartSec = "10s";
      TimeoutStopSec = "40s";
    };
  };

  ############################################################################
  # Operations (status checks, image update, secret rotation, access URLs,
  # the missing-email limitation): docs/runbooks/multica.md, docs/services/multica.md.
  ############################################################################
}
