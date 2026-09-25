{ config, lib, pkgs, ... }:

##############################################################################
# AutoMuteUs (Among Us auto-mute Discord bot), self-hosted: the official
# automuteus/deploy docker-compose.yml ported to podman, 5 containers
# (bot, galactus, api, redis, postgres), same pattern as modules/multica.nix.
#
# Docs:
#   docs/services/automuteus.md   what it is, access, secrets, operations
#   docs/network.md               Serve ports 9449 (galactus) / 9450 (api)
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  # bot / galactus / api are released together under one version.
  # https://github.com/automuteus/automuteus/releases
  tag = "9.2.1";

  # Container-internal ports (fixed by the upstream compose file).
  brokerPort = 8123; # galactus: AmongUsCapture connects here (socket.io)
  apiContainerPort = 5000;

  # Host-side (127.0.0.1) publish ports; exposed to the tailnet only via
  # Tailscale Serve (modules/reverse-proxy.nix, 9449/9450). 8080 is taken by
  # Open WebUI, 8082/8083 by Multica.
  galactusHostPort = 8123;
  apiHostPort = 8084;

  # DISCORD_BOT_TOKEN, POSTGRES_PASS, POSTGRES_PASSWORD (same value as
  # POSTGRES_PASS; the postgres image reads the latter name).
  secretsFile = config.age.secrets.automuteus-env.path;

  commonEnv = {
    REDIS_ADDR = "automuteus-redis:6379";
    POSTGRES_ADDR = "automuteus-postgres:5432";
    POSTGRES_USER = "automuteus";
  };
in
{
  age.secrets.automuteus-env = {
    file = ../secrets/automuteus-env.age;
    mode = "0400";
  };

  # Longer than the containers' --stop-timeout below, so systemd doesn't
  # SIGKILL podman mid-drain.
  systemd.services.podman-automuteus.serviceConfig.TimeoutStopSec = lib.mkForce 150;
  systemd.services.podman-automuteus-galactus.serviceConfig.TimeoutStopSec = lib.mkForce 60;

  virtualisation.oci-containers.containers = {
    automuteus-redis = {
      image = "docker.io/library/redis:alpine";
      volumes = [ "automuteus-redis:/data" ];
      autoStart = true;
    };

    automuteus-postgres = {
      # Major-version bumps can't open an existing volume without a migration
      # (upstream README "Upgrading Postgres").
      image = "docker.io/library/postgres:18-alpine";
      environment.POSTGRES_USER = commonEnv.POSTGRES_USER;
      environmentFiles = [ secretsFile ]; # POSTGRES_PASSWORD
      # Postgres 18+ keeps data in a version-specific dir under /var/lib/postgresql.
      volumes = [ "automuteus-pgdata:/var/lib/postgresql" ];
      autoStart = true;
    };

    automuteus-galactus = {
      image = "docker.io/automuteus/galactus:${tag}";
      dependsOn = [ "automuteus-redis" ];
      ports = [ "127.0.0.1:${toString galactusHostPort}:${toString brokerPort}" ];
      environment = {
        BROKER_PORT = toString brokerPort;
        REDIS_ADDR = commonEnv.REDIS_ADDR;
      };
      # Drains capture clients and unmutes everyone on SIGTERM (upstream uses 30s).
      extraOptions = [ "--stop-timeout=30" ];
      autoStart = true;
    };

    automuteus-api = {
      image = "docker.io/automuteus/api:${tag}";
      dependsOn = [ "automuteus-redis" "automuteus-postgres" ];
      ports = [ "127.0.0.1:${toString apiHostPort}:${toString apiContainerPort}" ];
      environment = commonEnv // {
        API_PORT = toString apiContainerPort;
        # HOST / API_SERVER_URL depend on the Tailscale Serve URL, so they're
        # set in modules/reverse-proxy.nix (same rule as Multica).
      };
      environmentFiles = [ secretsFile ]; # POSTGRES_PASS
      autoStart = true;
    };

    automuteus = {
      image = "docker.io/automuteus/automuteus:${tag}";
      dependsOn = [ "automuteus-redis" "automuteus-postgres" "automuteus-galactus" "automuteus-api" ];
      environment = commonEnv;
      # HOST / API_SERVER_URL: modules/reverse-proxy.nix.
      environmentFiles = [ secretsFile ]; # DISCORD_BOT_TOKEN, POSTGRES_PASS
      volumes = [ "automuteus-logs:/app/logs" ];
      extraOptions = [ "--stop-timeout=120" ];
      autoStart = true;
    };
  };
}
