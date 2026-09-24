{ config, lib, pkgs, ... }:

##############################################################################
# Ollama (local LLM inference server) and Open WebUI.
#
# Ollama is disabled (services.ollama.enable = false, since 2026-09-21) — inference
# moved to llama.cpp (modules/llama-cpp.nix, 127.0.0.1:8888). Open WebUI still runs
# from this module.
#
# Docs (history, measurements, caller-facing notes are not comments here):
#   docs/services/ollama.md                          status, re-enable steps, ops
#   docs/services/open-webui.md                       what it is, gotchas
#   docs/decisions/2026-08-02-ollama-model-selection.md
#   docs/decisions/2026-08-12-ollama-gpu-topology.md
#   docs/decisions/2026-09-06-openviking-model-consolidation.md
#   docs/decisions/2026-09-23-ollama-to-llama-cpp.md  the migration itself
#   docs/gpu-vram-budget.md                           card table, VRAM budget
#
# Ran as a native systemd service rather than a container: simpler than setting up
# GPU passthrough (CDI / nvidia-container-toolkit) for podman, fewer moving parts.
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  ports = {
    ollama = 11434;
    openWebui = 8080; # monitoring.nix's cadvisor is 8081, no conflict
  };
in
{
  ############################################################################
  # Ollama
  ############################################################################
  services.ollama = {
    # Disabled 2026-09-21 in favor of llama.cpp (modules/llama-cpp.nix,
    # 127.0.0.1:8888) — the two GPUs (13.6 GiB total) can't hold ollama's
    # OpenViking models and llama.cpp's Bonsai at once. Rest of this block is
    # left in place to re-enable: flip this back to true, stop llama-cpp.service
    # first, and see docs/services/ollama.md#how-to-re-enable for the rest
    # (including the commented-out systemd.services.ollama block below).
    # enable = true;
    enable = false;

    # unstable for CUDA support and a current version — see docs/services/ollama.md.
    package = pkgs.unstable.ollama-cuda;

    # **Required alongside `package`, or the CUDA build is silently discarded.**
    # The upstream module overrides cfg.package with `acceleration` (default
    # null), which strips CUDA back out unless set explicitly here. See
    # docs/services/ollama.md for the failure mode hit on this host.
    acceleration = "cuda";

    # DynamicUser (user/group left at default null) — do not "fix" this to a
    # static user, it won't change where the state directory actually lives.
    # See docs/services/ollama.md for why /var/lib/ollama is a symlink.
    home = "/var/lib/ollama";
    # modelsDir defaults to ${home}/models

    # 0.0.0.0; reachability is controlled by the firewall block below, same
    # policy as Grafana (Tailscale IPs aren't known at build time).
    host = "0.0.0.0";
    port = ports.ollama;
    openFirewall = false;

    environmentVariables = {
      ########################################################################
      # Pool both GPUs into a single ~14 GiB budget
      ########################################################################

      # ★ Required or CUDA_VISIBLE_DEVICES below points at the wrong GPU ★
      # See docs/decisions/2026-08-12-ollama-gpu-topology.md.
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";

      # Faster 3060 Ti first — see docs/decisions/2026-08-12-ollama-gpu-topology.md.
      CUDA_VISIBLE_DEVICES = "1,0";

      # Split models across both cards even when one would fit alone.
      # ★ Not necessarily a speedup — measure before trusting this. ★
      # See docs/decisions/2026-08-12-ollama-gpu-topology.md.
      OLLAMA_SCHED_SPREAD = "1";

      ########################################################################
      # VRAM savings
      ########################################################################
      OLLAMA_FLASH_ATTENTION = "1";

      # q8_0 KV cache roughly halves KV memory use; supported on both sm_75 and
      # sm_86. If output looks wrong, rule this out first.
      OLLAMA_KV_CACHE_TYPE = "q8_0";

      ########################################################################
      # Residency and scheduling
      ########################################################################

      # Keeps embedding + vlm both resident for OpenViking (avoids per-request
      # load/unload thrash). See
      # docs/decisions/2026-09-06-openviking-model-consolidation.md for the
      # incident this fixed and why 2 is sufficient.
      OLLAMA_MAX_LOADED_MODELS = "2";

      # 4C/8T CPU — keep concurrent requests low; more parallelism costs VRAM
      # via extra KV cache.
      OLLAMA_NUM_PARALLEL = "1";

      # Keep models resident between calls; loading from NVMe takes seconds.
      # Shorten this if VRAM needs freeing up sooner.
      OLLAMA_KEEP_ALIVE = "30m";
    };

    # Pulled automatically after the service starts; first rebuild downloads
    # ~15 GiB total. See docs/decisions/2026-08-02-ollama-model-selection.md
    # for the sizing rule and benchmark behind this list.
    loadModels = [
      "qwen2.5-coder:7b" # code assistance, Q4 ~4.7 GiB, fits the 3060 Ti alone
      "gemma4:12b"       # general chat via Open WebUI. Previously doubled as
                         # OpenViking's vlm; dropped that role for tool-call
                         # reliability reasons — see
                         # docs/decisions/2026-09-08-openviking-vlm-selection.md.
                         # Kept for Open WebUI's own chat use.
      "qwen3.5:9b"       # OpenViking's vlm/query_planner model (era before the
                         # llama.cpp migration) — see
                         # docs/decisions/2026-09-08-openviking-vlm-selection.md.
                         # ~6.6 GiB, tool-calling confirmed via `ollama show`.
      # No longer used by anything (2026-09-23) — RAG embedding moved to
      # llama-swap's [embedding]. Kept only because this whole loadModels block
      # is a restore point for `enable = true`; not required to re-enable.
      "nomic-embed-text"   # ~0.3 GiB
      "qwen3-embedding:4b" # OpenViking's embedding model — Matryoshka-trained,
                            # truncatable to the 2048 dimensions the bundled
                            # bootstrap collection expects. Q4_K_M, ~2.5 GiB.
      # guoxuter/ov_intent_analysis_sft:v7_q8 (former dedicated query_planner
      # model) removed 2026-09-06 — see
      # docs/decisions/2026-09-06-openviking-model-consolidation.md. Pulled
      # models aren't auto-removed by deleting them from this list; run
      # `ollama rm guoxuter/ov_intent_analysis_sft:v7_q8` if still present.
    ];

    # services.ollama.syncModels (removes undeclared models) isn't in 25.05
    # yet; manually `ollama pull`-ed models are left alone as usual.
  };

  # Start only once the GPU is usable (driver is initialized once
  # nvidia-persistenced is up).
  #
  # Commented out alongside `enable = false` above: with services.ollama
  # disabled, no ollama.service unit exists for after/wants to attach to, and
  # leaving this active would create a unit with no ExecStart. Restore
  # alongside re-enabling ollama.
  # systemd.services.ollama = {
  #   after = [ "nvidia-persistenced.service" ];
  #   wants = [ "nvidia-persistenced.service" ];
  # };

  ############################################################################
  # Open WebUI
  #
  # Ollama itself has no authentication; all browser access and account
  # management goes through here instead. See docs/services/open-webui.md.
  ############################################################################
  services.open-webui = {
    enable = true;

    # unstable, to track ollama's version — see docs/services/open-webui.md
    # for why, the non-free license change, and the alembic migration caveat.
    package = pkgs.unstable.open-webui;

    host = "0.0.0.0";
    port = ports.openWebui;
    openFirewall = false; # opened below, alongside ollama's port

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
      # docs/services/open-webui.md.
      OLLAMA_BASE_URL = "http://127.0.0.1:${toString ports.ollama}";

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

  ############################################################################
  # Exposure: tailscale0 only, not the LAN. Ollama's API has no auth, so LAN
  # exposure would let anyone on the network run/delete models.
  #
  # Open WebUI (8080) is not opened here — reachable only via Tailscale Serve
  # (modules/reverse-proxy.nix). Ollama's 11434 is opened directly instead,
  # since ollama CLI / OLLAMA_HOST clients can't target a sub-path base URL;
  # tailnet-only exposure is unchanged either way.
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    ports.ollama
  ];

  # ollama CLI for `ollama list/ps/pull`; same CUDA build as the service to
  # avoid version skew.
  environment.systemPackages = [ config.services.ollama.package ];

  # Ops notes, benchmarking procedure, storage details: docs/services/ollama.md
  # and docs/services/open-webui.md.
}
