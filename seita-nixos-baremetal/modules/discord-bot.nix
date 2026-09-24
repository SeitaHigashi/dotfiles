{ config, pkgs, inputs, ... }:

##############################################################################
# Discord Gateway bot -> n8n webhook forwarder.
#
# Docs:
#   docs/services/discord-bot.md   why Gateway not Interactions, secrets, notes
#
# When you change this file, update the doc above in the same commit.
##############################################################################

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  agenixPkg = inputs.agenix.packages.${pkgs.system}.default;
in
{
  environment.systemPackages = [ agenixPkg ];

  # Must be an ssh-to-age-converted key, not the raw SSH host key directly —
  # agenix's built-in SSH support fails against it ("no identity matched").
  # Provisioned manually (like the Grafana admin password), not in git.
  # Rationale and recreation steps:
  # docs/decisions/2026-08-05-agenix-ssh-to-age-host-key.md.
  age.identityPaths = [ "/etc/age/host.key" ];

  age.secrets.discord-bot-env = {
    file = ../secrets/discord-bot-env.age;
    owner = "discord-bot";
    mode = "0400";
  };

  users.users.discord-bot = {
    isSystemUser = true;
    group = "discord-bot";
  };
  users.groups.discord-bot = { };

  systemd.services.discord-bot = {
    description = "Discord Gateway bot -> n8n webhook forwarder";
    after = [ "network-online.target" "n8n.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pythonEnv}/bin/python3 ${./discord-bot/bot.py}";
      EnvironmentFile = config.age.secrets.discord-bot-env.path;
      Restart = "on-failure";
      RestartSec = "10s";
      User = "discord-bot";
      Group = "discord-bot";
    };
  };
}
