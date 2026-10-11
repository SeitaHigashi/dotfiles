{ config, lib, pkgs, ... }:

##############################################################################
# Open WebUI (browser chat UI and account management for the local LLMs).
#
# Split out of modules/ollama.nix on 2026-10-11 so that the disabled Ollama
# module no longer carries a running service.
#
# Docs: docs/services/open-webui.md   what it is, gotchas
#       docs/decisions/2026-09-23-ollama-to-llama-cpp.md
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  port = 8080; # monitoring.nix's cadvisor is 8081, no conflict
in
{
  services.open-webui = {
    enable = true;

    # unstable, to track ollama's version — see docs/services/open-webui.md
    # for why, the non-free license change, and the alembic migration caveat.
    package = pkgs.unstable.open-webui;

    # Not opened in the firewall: reachable only via Tailscale Serve
    # (modules/reverse-proxy.nix).
    host = "0.0.0.0";
    inherit port;
    openFirewall = false;

    environment = {
      # ★ Required or 0.11.0 fails to start. ★ The 25.05 module passes these
      # as relative paths, which open-webui 0.6.18+ can't handle correctly.
      # See docs/services/open-webui.md for the exact failure and why
      # `// cfg.environment` lets us override without patching the module.
      STATIC_DIR = "${config.services.open-webui.stateDir}/static";
      DATA_DIR = "${config.services.open-webui.stateDir}/data";
      HF_HOME = "${config.services.open-webui.stateDir}/hf_home";
      SENTENCE_TRANSFORMERS_HOME = "${config.services.open-webui.stateDir}/transformers_home";

      # PersistentConfig seed only, not necessarily the live value — see
      # docs/services/open-webui.md. 11434 is modules/ollama.nix's port
      # (nothing listens there while Ollama is disabled).
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";

      # Requires the admin account created on first access. False lets anyone
      # on the tailnet straight in.
      WEBUI_AUTH = "True";

      # No outbound telemetry — closed host, nothing to send it to.
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";

      # RAG embedding, moved from ollama to llama-swap on 2026-09-23 — see
      # docs/decisions/2026-09-23-ollama-to-llama-cpp.md for the outage this
      # fixed (RAG silently never embedded anything for two days) and why
      # these are PersistentConfig seeds, not necessarily the live value.
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_OPENAI_API_BASE_URL = "http://127.0.0.1:8888/v1";
      RAG_OPENAI_API_KEY = "dummy"; # llama-swap doesn't check this, but rejects empty
      RAG_EMBEDDING_MODEL = "embedding";
    };
  };
}
