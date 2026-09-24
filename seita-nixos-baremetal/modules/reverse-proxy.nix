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

  # Each of these gets its own port because it can't live under a subpath —
  # see docs/network.md for the per-app reasons.
  n8nUrl = "https://${fqdn}:8443";
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
    { path = null;       httpsPort = 443;   port = 8080;                          note = "open-webui"; }
    { path = null;       httpsPort = 9448;  port = 8888;                          note = "llama.cpp (no auth, tailnet only)"; }
    { path = "/grafana"; httpsPort = 443;   port = 3000;                          note = "grafana"; }
    { path = null;       httpsPort = 8443;  port = 5678;                          note = "n8n"; }
    # Disabled with ComfyUI (2026-09-24, modules/comfyui.nix enable = false); uncomment together.
    # { path = null;       httpsPort = 9443;  port = 8188;                          note = "comfyui"; }
    { path = null;       httpsPort = 9444;  port = 3001;                          note = "multica-frontend"; }
    { path = null;       httpsPort = 9445;  port = 8082;                          note = "multica-backend"; }
    { path = null;       httpsPort = 9446;  port = 8765;                          note = "fukurou-webui"; }
    { path = null;       httpsPort = 9447;  port = 7878;                          note = "fukurou-server (wss, for fukurou-webui)"; }
    { path = null;       httpsPort = 10000; port = multicaGithubWebhookProxyPort; note = "multica-github-webhook (via nginx)"; funnel = true; }
  ];

  # HTTPS ports Serve/Funnel use (what the firewall opens)
  httpsPorts = lib.unique (map (r: r.httpsPort) routes);

  tailscaleBin = "${config.services.tailscale.package}/bin/tailscale";

  serveCommand = r:
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
  # leaving stale state behind.
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

      ${lib.concatMapStringsSep "\n" serveCommand routes}
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
  services.grafana.settings.server = {
    root_url = "${baseUrl}/grafana/";
    serve_from_sub_path = false;
  };

  # --- n8n -----------------------------------------------------------------
  # N8N_PATH is deliberately not set (docs/network.md — it would break LAN
  # direct access). N8N_PROXY_HOPS makes rate-limit/audit-log IPs meaningful
  # (otherwise n8n sees tailscaled's own IP as the client). webhookUrl uses
  # the dedicated option, not environment, because the n8n NixOS module
  # unconditionally defines WEBHOOK_URL = "" and a duplicate in `environment`
  # would conflict at eval time.
  services.n8n.webhookUrl = "${n8nUrl}/";

  systemd.services.n8n.environment = {
    N8N_PROXY_HOPS = "1";
    N8N_EDITOR_BASE_URL = "${n8nUrl}/";
  };

  # --- Open WebUI ------------------------------------------------------------
  # Used for generating share-link / email URLs only (listens at / either way).
  services.open-webui.environment = {
    WEBUI_URL = baseUrl;
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
