{
  description = "Bonsai-27B (prism-ml) on the PrismML llama.cpp fork";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # PrismML fork of llama.cpp. The `prism` branch carries the ternary /
    # 1-bit kernels (Q1_0_g128, Q2_0_g128, PTQ1_0, PQ2_0) and the Hadamard
    # rotation logic that mainline llama.cpp does not have.
    llama-cpp-prism = {
      url = "github:PrismML-Eng/llama.cpp/prism";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, llama-cpp-prism }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true; # CUDA
          cudaSupport = true;
          # GTX 1660 SUPER = sm_75, RTX 3060 Ti = sm_86
          cudaCapabilities = [ "7.5" "8.6" ];
          cudaForwardCompat = false;
        };
      };

      pkgsCpu = import nixpkgs { inherit system; };

      mkPrism = base:
        base.overrideAttrs (old: {
          pname = "llama-cpp-prism";
          version = llama-cpp-prism.shortRev or "dirty";
          src = llama-cpp-prism;
          # The fork tracks upstream loosely; don't let nixpkgs patches fight it.
          patches = [ ];
          doCheck = false;
        });
      # Strip the `. .../_config.sh` line and splice the config in literally, so the
      # script is self-contained in the store.
      inlineConfig = path:
        builtins.replaceStrings
          [ ''. "$(dirname "$0")/_config.sh"'' ]
          [ (builtins.readFile ./scripts/_config.sh) ]
          (builtins.readFile path);
    in
    {
      packages.${system} = rec {
        # CUDA build (default on this host).
        llama-cpp-prism-cuda = mkPrism (pkgs.llama-cpp.override { cudaSupport = true; });

        # Pure CPU build, useful for debugging kernel/driver issues.
        llama-cpp-prism-cpu = mkPrism pkgsCpu.llama-cpp;

        # Vulkan build: works across both GPUs without CUDA toolchain.
        llama-cpp-prism-vulkan = mkPrism (pkgsCpu.llama-cpp.override { vulkanSupport = true; });

        # `ollama run`-style one-liners. The scripts source ./scripts/_config.sh via
        # `dirname $0`, which does not hold once they are copied into the store, so
        # the shared config is inlined ahead of the body instead.
        bonsai = pkgsCpu.writeShellApplication {
          name = "bonsai";
          runtimeInputs = [ llama-cpp-prism-cuda ];
          text = inlineConfig ./scripts/run-cli.sh;
        };

        bonsai-chat = pkgsCpu.writeShellApplication {
          name = "bonsai-chat";
          runtimeInputs = [ llama-cpp-prism-cuda pkgsCpu.curl ];
          text = builtins.readFile ./scripts/chat.sh;
        };

        bonsai-router = pkgsCpu.writeShellApplication {
          name = "bonsai-router";
          runtimeInputs = [ llama-cpp-prism-cuda ];
          text = inlineConfig ./scripts/run-router.sh;
        };

        bonsai-server = pkgsCpu.writeShellApplication {
          name = "bonsai-server";
          runtimeInputs = [ llama-cpp-prism-cuda ];
          text = inlineConfig ./scripts/run-server.sh;
        };

        default = llama-cpp-prism-cuda;
      };

      apps.${system} =
        let
          p = self.packages.${system}.default;
          pkgs' = self.packages.${system};
        in {
          # nix run .#bonsai  ->  interactive chat, like `ollama run`
          bonsai = { type = "app"; program = "${pkgs'.bonsai}/bin/bonsai"; };
          bonsai-server = { type = "app"; program = "${pkgs'.bonsai-server}/bin/bonsai-server"; };
          bonsai-router = { type = "app"; program = "${pkgs'.bonsai-router}/bin/bonsai-router"; };
          bonsai-chat = { type = "app"; program = "${pkgs'.bonsai-chat}/bin/bonsai-chat"; };
          cli = { type = "app"; program = "${p}/bin/llama-cli"; };
          server = { type = "app"; program = "${p}/bin/llama-server"; };
          bench = { type = "app"; program = "${p}/bin/llama-bench"; };
          default = self.apps.${system}.bonsai;
        };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          self.packages.${system}.default
          self.packages.${system}.bonsai
          self.packages.${system}.bonsai-server
          self.packages.${system}.bonsai-router
          self.packages.${system}.bonsai-chat
          pkgsCpu.curl
          pkgsCpu.jq
        ];
        shellHook = ''
          export BONSAI_MODEL_DIR="''${BONSAI_MODEL_DIR:-/var/lib/llm-models}"
          mkdir -p "$BONSAI_MODEL_DIR"
          echo "llama.cpp (PrismML fork) ready."
          echo "  bonsai          interactive chat (like: ollama run)"
          echo "  bonsai-server   single-model OpenAI server + web UI on :8888"
          echo "  bonsai-router   multi-model router, load on demand (like: ollama serve)"
          echo "  llama-cli / llama-server / llama-bench   raw binaries"
          echo "Models dir: $BONSAI_MODEL_DIR   (./scripts/download-model.sh to fetch)"
        '';
      };
    };
}
