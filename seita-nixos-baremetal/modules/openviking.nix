{ config, lib, pkgs, ... }:

##############################################################################
# OpenViking (self-evolving context DB for AI agents: agent memory, knowledge
# RAG, skills) run as a podman container.
#
# Docs (history, measurements, caller-facing notes are not comments here):
#   docs/services/openviking.md                          overview, backend, ops
#   docs/runbooks/openviking.md                           image update, secret rotation
#   docs/decisions/2026-09-06-openviking-model-consolidation.md
#   docs/decisions/2026-09-08-openviking-vlm-selection.md
#   docs/decisions/2026-09-21-openviking-llama-cpp-migration.md
#   docs/decisions/2026-09-23-ollama-to-llama-cpp.md      the migration itself
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  port = 1933;

  workspaceDir = "/var/lib/openviking";

  rootApiKeyFile = config.age.secrets.openviking-root-api-key.path;

  # Migrated from ollama to llama.cpp (modules/llama-cpp.nix) 2026-09-21 — see
  # docs/decisions/2026-09-21-openviking-llama-cpp-migration.md. Both backends
  # are OpenAI-compatible, so only api_base and model names change; `model`
  # values below are llama-swap model IDs (modules/llama-cpp.nix swapConfig),
  # not ollama tags.
  #
  # llama-cpp.service auto-starts (multi-user.target, since 2026-09-23 — see
  # docs/decisions/2026-09-23-ollama-to-llama-cpp.md). If it's ever stopped,
  # OpenViking enters a retry loop on /embeddings.
  # ollamaBaseUrl = "http://127.0.0.1:11434/v1";
  inferenceBaseUrl = "http://127.0.0.1:8888/v1";

  # Non-secret part of ov.conf; root_api_key is spliced in by the oneshot unit
  # below. provider = "openai" is openviking's generic OpenAI-compatible value
  # (confirmed against openviking_cli/utils/config/{embedding,vlm}_config.py
  # in the container image).
  #
  # embedding's structure differs from vlm's: EmbeddingConfig requires
  # provider/api_base nested under dense/sparse/hybrid rather than at the top
  # level (embedding_config.py's EmbeddingConfig.validate_config) — a
  # top-level placement fails at startup with "Unknown config field
  # 'embedding.api_base'" (confirmed on this host). vlm's VLMConfig is flat,
  # so no nesting is needed there.
  ovConfTemplate = pkgs.writeText "ov.conf.template" (builtins.toJSON {
    server = {
      host = "0.0.0.0";
      inherit port;
      cors_origins = [ "*" ];
    };
    storage = {
      workspace = "/app/.openviking/data";
      agfs.backend = "local";
      vectordb.backend = "local";
    };
    embedding = {
      dense = {
        provider = "openai";
        api_base = inferenceBaseUrl;
        api_key = "llamacpp"; # llama.cpp doesn't check this either, dummy value
        # llama-swap's "embedding" preset (Qwen3-Embedding-4B, Q4_K_M) on the
        # 1660 SUPER (CUDA_VISIBLE_DEVICES=0) so it never competes with bonsai
        # for the 3060 Ti — see modules/llama-cpp.nix swapConfig for the
        # current GPU assignment and docs/gpu-vram-budget.md for measurements.
        # model = "qwen3-embedding:4b";
        model = "embedding";
        # ★ 2048 is still correct; no reindex needed. ★ See
        # docs/decisions/2026-09-21-openviking-llama-cpp-migration.md for why
        # llama.cpp ignoring the `dimensions` request field doesn't matter
        # here, and the measured similarity delta from truncating client-side.
        dimension = 2048;
      };

      # ★ Required or startup fails (hit on this host 2026-09-21). ★ Renaming
      # the model alone (not the dimension) makes OpenViking's stored
      # collection metadata mismatch the config; this flag lets it rewrite the
      # metadata and keep existing vectors. See
      # docs/decisions/2026-09-21-openviking-llama-cpp-migration.md for the
      # exact error, the flag's scope, and the accepted risk (vectors are now
      # produced by a different embedding backend than the ones already
      # stored).
      allow_metadata_override = true;
    };
    vlm = {
      provider = "openai";
      api_base = inferenceBaseUrl;
      api_key = "llamacpp";
      # llama-swap's [bonsai] preset (Ternary-Bonsai-2-27B, PTQ1_0). Chosen
      # over qwen3.5:9b for tool-call reliability — see
      # docs/decisions/2026-09-21-openviking-llama-cpp-migration.md for the
      # benchmark.
      # model = "qwen3.5:9b";
      model = "bonsai";
      # llama.cpp has no per-request context override (fixed per preset at
      # server startup, see modules/llama-cpp.nix for [bonsai]'s current
      # value) so the num_ctx this used to carry under ollama was dropped.
      # reasoning_effort = "none" suppresses reasoning tokens on this
      # JSON-only workload; confirmed effective under llama.cpp. See
      # docs/decisions/2026-09-21-openviking-llama-cpp-migration.md (and
      # docs/decisions/2026-09-08-openviking-vlm-selection.md for the ollama-era
      # mechanics this replaced).
      # extra_request_body = { options.num_ctx = 16384; reasoning_effort = "none"; };
      extra_request_body = { reasoning_effort = "none"; };
    };
    query_planner = {
      provider = "openai";
      api_base = inferenceBaseUrl;
      api_key = "llamacpp";
      # model = "qwen3.5:9b";
      model = "bonsai"; # unified with vlm's preset — see
                         # docs/decisions/2026-09-06-openviking-model-consolidation.md
      # Same reasoning_effort rationale as vlm above; num_ctx was never needed
      # here since query-expansion prompts are short.
      extra_request_body = { reasoning_effort = "none"; };
    };
  });
in
{
  age.secrets.openviking-root-api-key = {
    file = ../secrets/openviking-root-api-key.age;
    mode = "0400";
  };

  ############################################################################
  # Data directory (dpool/var/lib/openviking, disko/default.nix)
  #
  # Container runs as root (no USER in the official Dockerfile), so unlike FTB
  # Evolution there's no uid/gid to match.
  ############################################################################
  systemd.tmpfiles.rules = [
    "d ${workspaceDir} 0700 root root -"
  ];

  ############################################################################
  # Render ov.conf before the container starts: splice root_api_key (agenix)
  # into the static template with jq. Ordered before podman-openviking.service
  # via before/requires (same pattern as modules/multica.nix's
  # multica-github-secret).
  ############################################################################
  systemd.services.openviking-conf = {
    description = "Render OpenViking ov.conf with root_api_key from agenix";
    before = [ "podman-openviking.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openviking-render-conf" ''
        set -euo pipefail
        ${pkgs.jq}/bin/jq \
          --arg root_api_key "$(cat ${rootApiKeyFile})" \
          '.server.root_api_key = $root_api_key' \
          ${ovConfTemplate} > ${workspaceDir}/ov.conf.tmp
        mv ${workspaceDir}/ov.conf.tmp ${workspaceDir}/ov.conf
        chmod 0600 ${workspaceDir}/ov.conf
      '';
    };
  };

  systemd.services.podman-openviking = {
    after = [ "openviking-conf.service" ];
    requires = [ "openviking-conf.service" ];
  };

  ############################################################################
  # Container. See docs/services/openviking.md for why --network=host.
  ############################################################################
  virtualisation.oci-containers.containers.openviking = {
    image = "ghcr.io/volcengine/openviking:latest";
    volumes = [ "${workspaceDir}:/app/.openviking" ];
    extraOptions = [
      "--network=host"
    ];
    autoStart = true;
  };

  ############################################################################
  # Exposure: tailscale0 only, not the LAN (same policy as ollama).
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

  # Ops notes, runbook: docs/services/openviking.md, docs/runbooks/openviking.md
}
