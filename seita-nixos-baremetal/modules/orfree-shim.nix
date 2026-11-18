{ config, lib, pkgs, ... }:

##############################################################################
# orfree shim: OpenRouter :free first, local "chat" alias as fallback.
#
#   client -> llama-swap :8888 (model "orfree/auto") -> shim :8795 -> OpenRouter
#                                                          \-> (on failure) llama-swap :8888, model "chat" (role alias, currently bonsai)
#
# llama-swap has no response-based fallback (spillover picks before the
# request; peer 429s are passed straight to the client), hence this shim.
# It is a llama-swap *peer* (see peers: in modules/llama-cpp.nix), so it takes
# no part in the matrix and calling back into llama-swap cannot evict itself.
# Docs: docs/services/llama-cpp.md ("orfree/auto").
#
# Off by default so the build passes before the secret exists.
# Provisioning (user steps):
#   1. cd secrets && agenix -e orfree-env.age     (entry already in secrets.nix)
#      contents:  OPENROUTER_API_KEY=sk-or-...
#   2. set  services.orfreeShim.enable = true;  (flake.nix / host config)
#   3. sudo nixos-rebuild switch --flake .#seita-nixos-baremetal
#   4. units to restart (switch does not touch running units):
#        systemctl restart llama-cpp   # only if the peers: block is new to the running yaml
#      orfree-shim is new, so switch starts it.
# Privacy: free OpenRouter endpoints may log/train on prompts. Owner policy
# (2026-11-15, SEI-279): only credentials must not leave the host; personal/health
# content may. The shim enforces that with a regex screen (SECRET_RE in shim.py):
# a body that matches is always served locally, in every mode.
# Previous policy (kept for the record): "do not point health/n8n data at orfree/auto".
#
# orfree/overflow (SEI-279): local while the model behind "chat" is idle,
# OpenRouter only while it is busy or not loaded. ORFREE_BUSY_MODEL (default
# "bonsai", in shim.py) must name the real llama-swap model behind "chat":
# /running lists real names only. Update it if the chat alias moves.
##############################################################################

let
  cfg = config.services.orfreeShim;
  m = import ../machine.nix;
in
{
  options.services.orfreeShim = {
    enable = lib.mkEnableOption "OpenRouter-free-first / local-fallback shim";
    port = lib.mkOption { type = lib.types.port; default = 8795; };
    # Verified against GET https://openrouter.ai/api/v1/models on 2026-11-15.
    # Tried in order; free ids churn, re-check if everything falls to local.
    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Last entry: OpenRouter's random free router (capability-filtered), tried
      # only after the pinned picks fail; then local "chat".
      default = [ "google/gemma-4-31b-it:free" "nvidia/nemotron-3-ultra-550b-a55b:free" "openrouter/free" ];
    };
    # Role alias, not a model id: follows whatever llama-swap maps "chat" to.
    localModel = lib.mkOption { type = lib.types.str; default = "chat"; };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.orfree-env = {
      file = ../secrets/orfree-env.age;
      owner = m.userName;
      mode = "0400";
    };

    systemd.services.orfree-shim = {
      description = "OpenRouter free -> local chat fallback shim (llama-swap peer)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        ORFREE_PORT = toString cfg.port;
        ORFREE_MODELS = lib.concatStringsSep "," cfg.models;
        ORFREE_LOCAL_MODEL = cfg.localModel;
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./orfree-shim/shim.py}";
        EnvironmentFile = config.age.secrets.orfree-env.path;
        User = m.userName;
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
