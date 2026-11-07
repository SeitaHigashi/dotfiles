{ config, lib, pkgs, ... }:

##############################################################################
# Consolidates HTTP services behind Tailscale Serve (reverse proxy).
#
# Docs:
#   docs/network.md   network boundary, why Serve not nginx, per-app subpath
#                      quirks, port list, and each service's dedicated-port
#                      rationale (Ollama bypass, Multica's two ports, the
#                      GitHub webhook Funnel nginx, fukurou wss)
#
# When you change this file, update docs/network.md in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  # tailnet MagicDNS suffix. Check with:
  #   tailscale status --json | grep MagicDNSSuffix
  # Changes if the tailnet is recreated (the cert name changes with it).
  tailnetSuffix = "tail5426c0.ts.net";

  fqdn = "${m.hostName}.${tailnetSuffix}";
  baseUrl = "https://${fqdn}";
  # Open WebUI as Tailscale Service svc:webui (docs/network.md "Tailscale Services").
  webuiUrl = "https://webui.${tailnetSuffix}";
  # Grafana as Tailscale Service svc:grafana (SEI-244).
  grafanaUrl = "https://grafana.${tailnetSuffix}";

  # Each of these gets its own port because it can't live under a subpath —
  # see docs/network.md for the per-app reasons.
  # n8n as Tailscale Service svc:n8n (SEI-247); rollback: "https://${fqdn}:8443".
  n8nUrl = "https://n8n.${tailnetSuffix}";
  comfyuiUrl = "https://${fqdn}:9443";
  multicaUrl = "https://${fqdn}:9444";
  # Backend-direct URL for multica-cli's daemon/runtime (docs/network.md).
  multicaBackendUrl = "https://${fqdn}:9445";
  # GitHub App webhook, reachable from the public internet (docs/network.md).
  multicaGithubWebhookUrl = "https://${fqdn}:10000";
  fukurouWebuiUrl = "https://${fqdn}:9446";
  # wss:// endpoint for fukurou-server, used by fukurou-webui (docs/network.md).
  fukurouServerWssUrl = "wss://${fqdn}:9447";
  llamaCppUrl = "https://${fqdn}:9448";
  # AutoMuteUs: AmongUsCapture connects to galactus and the API (tailnet only).
  automuteusGalactusUrl = "https://${fqdn}:9449";
  automuteusApiUrl = "https://${fqdn}:9450";

  # Must match modules/multica.nix's backendHostPort — the webhook relay
  # nginx below forwards to it.
  multicaBackendPort = 8082;
  # Port the relay nginx below listens on; Funnel forwards to backend through it.
  multicaGithubWebhookProxyPort = 8083;

  ############################################################################
  # Route table. path = null mounts at the root (/). httpsPort is the
  # listening HTTPS port. Full rationale (why each app needs its own port,
  # the Ollama /ollama trap, the Multica two-port split, the GitHub webhook
  # Funnel nginx, fukurou wss) is in docs/network.md — keep it updated when
  # you touch this table.
  #
  # ★ Do not mount Ollama at /ollama — it isn't mounted here at all. Ollama
  #   listens on tailscale0:11434 directly (modules/ollama.nix); mounting it
  #   under Open WebUI's root steals /ollama/* from Open WebUI's own proxy
  #   (docs/network.md).
  # ★ llama.cpp has no auth — tailnet-reachable (funnel = false) means
  #   anyone on the tailnet can use the model. Do not set funnel = true here.
  ############################################################################
  routes = [
    # Node-level open-webui row removed (SEI-243): Open WebUI is served only as svc:webui
    # below. Rollback: uncomment, and set WEBUI_URL back to baseUrl (docs/network.md).
    # { path = null;       httpsPort = 443;   port = 8080;                          note = "open-webui"; }
    { path = null;       httpsPort = 9448;  port = 8888;                          note = "llama.cpp (no auth, tailnet only)"; }
    # Node-level /grafana row removed (SEI-244): Grafana is served only as svc:grafana below
    # (with root_url on svc:grafana this path already 404'd). Node 443 is now empty.
    # Rollback: uncomment, and set root_url back to "${baseUrl}/grafana/" (docs/network.md).
    # { path = "/grafana"; httpsPort = 443;   port = 3000;                          note = "grafana"; }
    # Node-level 8443 n8n row removed (SEI-247): n8n is served only as svc:n8n below.
    # Tasker moved first; Seita waived the coexistence period. Rollback: uncomment, and set
    # n8nUrl back to "https://${fqdn}:8443" and Tasker back to :8443 (docs/network.md).
    # { path = null;       httpsPort = 8443;  port = 5678;                          note = "n8n"; }
    # Disabled with ComfyUI (2026-09-24, modules/comfyui.nix enable = false); uncomment together.
    # { path = null;       httpsPort = 9443;  port = 8188;                          note = "comfyui"; }
    { path = null;       httpsPort = 9444;  port = 3001;                          note = "multica-frontend"; }
    { path = null;       httpsPort = 9445;  port = 8082;                          note = "multica-backend"; }
    { path = null;       httpsPort = 9446;  port = 8765;                          note = "fukurou-webui"; }
    { path = null;       httpsPort = 9447;  port = 7878;                          note = "fukurou-server (wss, for fukurou-webui)"; }
    { path = null;       httpsPort = 9449;  port = 8123;                          note = "automuteus-galactus (AmongUsCapture)"; }
    { path = null;       httpsPort = 9450;  port = 8084;                          note = "automuteus-api (capture links)"; }
    # Node-level 9451 ~/share row removed (SEI-245): ~/share is served only as svc:share below.
    # Rollback: uncomment, and point ~/.claude/CLAUDE.md's default output URL back at :9451/
    # (docs/network.md). Never point it at ~ or / (tailscaled runs as root).
    # { path = null;       httpsPort = 9451;  port = "/home/${m.userName}/share";   note = "share dir (static files, tailnet only)"; }
    { path = null;       httpsPort = 9452;  port = 8090;                          note = "seita-health (web UI + ingest, tailnet only)"; }
    { path = null;       httpsPort = 10000; port = multicaGithubWebhookProxyPort; note = "multica-github-webhook (via nginx)"; funnel = true; }
    # Tailscale Service svc:webui (Open WebUI).
    # A row with `service` is applied after all plain rows (see serveCommand/script).
    # ★ Removing this row does NOT withdraw the advertisement: `serve reset` leaves
    #   Services alone. Drain it and run `tailscale serve clear svc:webui` by hand.
    { path = null;       httpsPort = 443;   port = 8080;   service = "webui";    note = "open-webui as Tailscale Service svc:webui"; }
    # Tailscale Service svc:grafana (SEI-244). Same drain + clear caveat as svc:webui.
    { path = null;       httpsPort = 443;   port = 3000;   service = "grafana";  note = "grafana as Tailscale Service svc:grafana"; }
    # Tailscale Service svc:share (SEI-245). Same drain + clear caveat as svc:webui.
    # Directory backend only ever ~/share (tailscaled runs as root: never ~ or /).
    { path = null;       httpsPort = 443;   port = "/home/${m.userName}/share"; service = "share"; note = "share dir as Tailscale Service svc:share"; }
    # Tailscale Service svc:llm (SEI-246): llama-swap. Same drain + clear caveat as svc:webui.
    # Node-level 9448 row stays until callers (nmtak16 share, other PCs) move here.
    # ★ No auth: never funnel this (Service rows are serve-only anyway).
    { path = null;       httpsPort = 443;   port = 8888;   service = "llm";      note = "llama-swap as Tailscale Service svc:llm (no auth, tailnet only)"; }
    # Tailscale Service svc:n8n (SEI-247): editor + webhooks. Same drain + clear caveat as svc:webui.
    # LAN :5678 (plain HTTP) is unchanged — opening n8n to the LAN is a standing decision.
    { path = null;       httpsPort = 443;   port = 5678;   service = "n8n";      note = "n8n as Tailscale Service svc:n8n"; }
  ];

  # Plain rows first (routes order), then Service rows (routes order): the unit runs
  # under set -euo pipefail, so a failing Service row must not abort the plain rows.
  plainRoutes = lib.filter (r: !(r ? service)) routes;
  serviceRoutes = lib.filter (r: r ? service) routes;

  # HTTPS ports Serve/Funnel use (what the firewall opens). Service rows are
  # deliberately included: traffic to a Service VIP still enters via tailscale0
  # on its httpsPort, so a Service on a port no plain row uses would be blocked
  # otherwise. 443 repeats across rows and is absorbed by lib.unique.
  httpsPorts = lib.unique (map (r: r.httpsPort) routes);

  tailscaleBin = "${config.services.tailscale.package}/bin/tailscale";

  serveCommand = r:
    if r ? service then
      "${tailscaleBin} serve --bg --yes --service=svc:${r.service} --https=${toString r.httpsPort} ${toString r.port}  # ${r.note}"
    else
    let
      setPath = lib.optionalString (r.path != null) "--set-path=${r.path} ";
      # Only funnel = true rows are exposed to the public internet; others are tailnet-only serve.
      subcommand = if (r.funnel or false) then "funnel" else "serve";
    in
    "${tailscaleBin} ${subcommand} --bg --yes --https=${toString r.httpsPort} ${setPath}${toString r.port}  # ${r.note}";
in
{
  ############################################################################
  # Apply the Serve config declaratively (`tailscale serve` state normally
  # lives only in /var/lib/tailscale, outside git/the Nix store — see
  # docs/network.md for why this is wrapped in a systemd unit instead).
  #
  # `serve reset` up front is why `routes` is the single source of truth:
  # removing a line here removes the mount from the live host too, instead of
  # leaving stale state behind. Exception: Tailscale Service rows (`service`)
  # — `serve reset` does not clear their advertisement; removing one needs a
  # manual drain + `tailscale serve clear svc:<name>`.
  #
  # ★ Renaming the host or the tailnet does NOT restart this unit ★ — the
  #   fqdn never appears in ExecStart (only --set-path/ports do). Run
  #   `sudo systemctl restart tailscale-serve` by hand after such a change
  #   (docs/network.md; hit during the 2026-08-01 host rename).
  ############################################################################
  systemd.services.tailscale-serve = {
    description = "Apply declarative Tailscale Serve configuration";

    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Fails if tailscaled isn't authenticated yet (before `sudo tailscale up`).
      # Retry rather than fail silently, so that's visible.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Wait for tailscaled to actually join the tailnet. after=tailscaled.service
      # only guarantees the process has started, not that the backend is Running yet —
      # calling serve before that fails.
      for _ in $(seq 1 60); do
        if ${tailscaleBin} status --json | grep -q '"BackendState": *"Running"'; then
          break
        fi
        sleep 2
      done

      # Rebuilt from scratch every time (see comment above).
      ${tailscaleBin} serve reset

      ${lib.concatMapStringsSep "\n" serveCommand (plainRoutes ++ serviceRoutes)}
    '';
  };

  ############################################################################
  # Firewall
  #
  # tailscale0 is not a trusted interface (other modules open ports on it
  # individually), so the ports Serve listens on (derived from `routes`) need
  # to be opened explicitly here.
  #
  # Grafana 3000 and Open WebUI 8080 are NOT open on tailscale0 (reach them
  # through Serve, or ssh -L). Other modules open their own direct ports on
  # tailscale0 (OpenViking 1933, fukurou-server 7878, ComfyUI 8188, Ollama
  # 11434 — the last has no listener while Ollama is disabled). Full list,
  # evaluated 2026-09-24: docs/network.md.
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = httpsPorts;

  # Directory served by svc:share; must exist and be readable by tailscaled.
  systemd.tmpfiles.rules = [ "d /home/${m.userName}/share 0755 ${m.userName} users -" ];

  ############################################################################
  # Relay nginx for the Multica GitHub webhook.
  #
  # Listens on 127.0.0.1 only, forwards only /api/webhooks/github to
  # multica-backend, 404s everything else. Doesn't terminate TLS (Funnel does
  # that upstream and forwards plaintext). Full rationale: docs/network.md.
  ############################################################################
  services.nginx = {
    enable = true;
    virtualHosts."multica-github-webhook" = {
      listen = [ { addr = "127.0.0.1"; port = multicaGithubWebhookProxyPort; } ];
      locations."= /api/webhooks/github" = {
        proxyPass = "http://127.0.0.1:${toString multicaBackendPort}/api/webhooks/github";
      };
      locations."/" = {
        extraConfig = "return 404;";
      };
    };
  };

  ############################################################################
  # Per-service follow-up config.
  #
  # Fronting a service with a proxy breaks any absolute URL/redirect it
  # generates itself unless it's told about the public URL. Kept here rather
  # than scattered in each service's own module so removing this module also
  # removes the follow-up config. Rationale for each: docs/network.md.
  ############################################################################

  # --- Grafana -----------------------------------------------------------
  # root_url is absolute, so monitoring.nix's `domain` setting is unused now.
  # serve_from_sub_path must stay false — see docs/network.md (setting it
  # true causes an infinite redirect loop, verified on hardware).
  # Points at svc:grafana (SEI-244); rollback: "${baseUrl}/grafana/" (docs/network.md).
  services.grafana.settings.server = {
    root_url = "${grafanaUrl}/";
    serve_from_sub_path = false;
  };

  # --- n8n -----------------------------------------------------------------
  # N8N_PATH is deliberately not set (docs/network.md — it would break LAN
  # direct access). N8N_PROXY_HOPS makes rate-limit/audit-log IPs meaningful
  # (otherwise n8n sees tailscaled's own IP as the client). WEBHOOK_URL
  # goes through `environment` since 26.05: the module's dedicated
  # webhookUrl option was removed and it no longer pre-defines
  # WEBHOOK_URL itself, so there is no conflict anymore.
  systemd.services.n8n.environment = {
    WEBHOOK_URL = "${n8nUrl}/";
    N8N_PROXY_HOPS = "1";
    N8N_EDITOR_BASE_URL = "${n8nUrl}/";
  };

  # --- Open WebUI ------------------------------------------------------------
  # Used for generating share-link / email URLs only (listens at / either way).
  # Points at svc:webui; rollback: set back to baseUrl (docs/network.md).
  services.open-webui.environment = {
    WEBUI_URL = webuiUrl;
  };

  # --- Multica -----------------------------------------------------------
  # CORS_ALLOWED_ORIGINS must list the actual browser Origin (multicaUrl) —
  # the backend's Upgrader.CheckOrigin rejects anything else, and
  # modules/multica.nix only knows the internal http://multica-frontend:3000.
  # Omitting this silently breaks the /ws websocket (docs/network.md,
  # confirmed on hardware 2026-08-12).
  # MULTICA_PUBLIC_URL uses the backend-direct URL, not multicaUrl, because
  # it's used to build webhook URLs that non-browser clients must be able to
  # reach directly.
  virtualisation.oci-containers.containers.multica-backend.environment = {
    FRONTEND_ORIGIN = multicaUrl;
    CORS_ALLOWED_ORIGINS = multicaUrl;
    MULTICA_APP_URL = multicaUrl;
    MULTICA_PUBLIC_URL = multicaBackendUrl;
  };

  # AutoMuteUs: HOST is the galactus URL and API_SERVER_URL the API URL that
  # the bot embeds in capture links; both must be reachable from the PC
  # running AmongUsCapture (modules/automuteus.nix, docs/services/automuteus.md).
  virtualisation.oci-containers.containers.automuteus.environment = {
    HOST = automuteusGalactusUrl;
    API_SERVER_URL = automuteusApiUrl;
  };
  virtualisation.oci-containers.containers.automuteus-api.environment = {
    HOST = automuteusGalactusUrl;
    API_SERVER_URL = automuteusApiUrl;
  };

  ############################################################################
  # Operational notes
  #
  #   Check applied state:
  #     systemctl status tailscale-serve
  #     tailscale serve status
  #
  #   Certificate (tailscaled fetches/renews automatically):
  #     tailscale cert ${fqdn}
  #
  #   URLs: see `routes` above and docs/network.md for what each one is.
  #   fukurou-server is also reachable directly at ws://<tailscale IP>:7878/
  #   (non-browser clients). Ollama was retired 2026-09-21
  #   (modules/ollama.nix, enable = false) — nothing listens on 11434 now.
  #
  #   Full rollback:
  #     remove ./modules/reverse-proxy.nix from flake.nix's `modules`, rebuild, then
  #     sudo tailscale serve reset
  ############################################################################
}
