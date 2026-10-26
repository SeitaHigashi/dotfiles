{ config, lib, pkgs, inputs, ... }:

##############################################################################
# seita-health (personal health & meal tracker, Rust/Axum + SQLite, developed
# at ~/src/seita-health): web UI and the ingest endpoint n8n posts to.
#
# Docs: docs/services/health.md (what it is, DB, rollout/rollback),
#       docs/network.md (Serve port 9452).
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  # Built by seita-health's own flake (crane), pinned in flake.lock via the
  # `seita-health` input. Pick up app changes with:
  #   nix flake update seita-health   (after committing in ~/src/seita-health)
  seitaHealth = inputs.seita-health.packages.${pkgs.system}.default;

  # The production DB stays where the CLI/MCP default points (cli.rs default_db),
  # so `seita-health` run by hand and this service share one file.
  dbPath = "/home/${m.userName}/src/seita-health/data/health.db";
in
{
  systemd.services.seita-health = {
    description = "seita-health web UI and ingest endpoint";

    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      SEITA_HEALTH_DB = dbPath;
      SEITA_HEALTH_ADDR = "127.0.0.1:8090"; # Serve 9452 -> here (modules/reverse-proxy.nix)
    };

    serviceConfig = {
      Type = "simple";
      # Same user as the CLI/MCP so the SQLite -wal/-shm files stay owned by one
      # account; ~ is 0700, so no other user could open the DB anyway.
      User = m.userName;
      WorkingDirectory = "/home/${m.userName}/src/seita-health";
      ExecStart = "${lib.getExe seitaHealth} serve";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
