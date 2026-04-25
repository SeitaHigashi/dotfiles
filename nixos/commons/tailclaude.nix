{ config, pkgs, lib, ... }:

let
  iiiPkg = pkgs.callPackage ../pkgs/iii.nix {};
  tailclaudePkg = pkgs.callPackage ../pkgs/tailclaude.nix {};

  tsx = "${tailclaudePkg}/lib/tailclaude/node_modules/.bin/tsx";
  indexTs = "${tailclaudePkg}/lib/tailclaude/src/index.ts";

  # iii engine config: absolute paths for state and exec, no file watching
  iiiConfig = pkgs.writeText "tailclaude-iii-config.yaml" ''
    modules:
      - class: modules::state::StateModule
        config:
          adapter:
            class: modules::state::adapters::KvStore
            config:
              store_method: file_based
              file_path: /var/lib/tailclaude/state_store.db

      - class: modules::api::RestApiModule
        config:
          port: 3111
          host: 127.0.0.1
          default_timeout: 180000
          cors:
            allowed_origins: ["*"]
            allowed_methods: [GET, POST, OPTIONS]

      - class: modules::queue::QueueModule
        config:
          adapter:
            class: modules::queue::BuiltinQueueAdapter

      - class: modules::pubsub::PubSubModule
        config:
          adapter:
            class: modules::pubsub::LocalAdapter

      - class: modules::cron::CronModule
        config:
          adapter:
            class: modules::cron::KvCronAdapter

      - class: modules::observability::OtelModule
        config:
          enabled: true
          service_name: tailclaude
          exporter: memory
          logs_enabled: true

      - class: modules::shell::ExecModule
        config:
          watch: []
          exec:
            - ${tsx} ${indexTs}
  '';
in
{
  # Writable state directory for SQLite database
  systemd.tmpfiles.rules = [
    "d /var/lib/tailclaude 0750 seita seita -"
  ];

  age.secrets.tailclaude-env = {
    file = ../secrets/tailclaude-env.age;
    owner = "seita";
  };

  systemd.services.tailclaude = {
    description = "TailClaude - Claude Code web interface via Tailscale";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "seita";
      Group = "seita";
      WorkingDirectory = "/var/lib/tailclaude";
      EnvironmentFile = config.age.secrets.tailclaude-env.path;
      Environment = [
        # iii needs Node.js; tailscale CLI is in /run/current-system/sw/bin
        # claude CLI is expected at /home/seita/.local/bin (installed by user)
        "PATH=${lib.makeBinPath [ pkgs.nodejs_20 iiiPkg ]}:/run/current-system/sw/bin:/home/seita/.local/bin"
        "NODE_ENV=production"
      ];
      ExecStart = "${iiiPkg}/bin/iii -c ${iiiConfig}";
      Restart = "on-failure";
      RestartSec = "10s";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
