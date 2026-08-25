{ config, lib, pkgs, ... }:

##############################################################################
# ComfyUI (Stable Diffusion 画像生成 Web UI) を comfy-cli 経由で venv に導入。
#
# 何のために入れるか:
#   ローカルでの画像生成。ollama と同じ NVIDIA GPU を使います。
#
# なぜ nixpkgs パッケージではなく pip venv か:
#   nixpkgs (stable/unstable とも) に comfyui/comfy-cli のパッケージが
#   存在しないため (2026-08-05 に nix search で確認)。comfy-cli は PyPI 配布の
#   CLI で、ComfyUI 本体を venv 内に pip でインストールする設計です。
#   ここでは python3/uv という前提パッケージと、それを起動する systemd unit
#   だけを Nix が提供します。ollama/n8n/open-webui のような nixpkgs/overlay
#   由来の正式パッケージとは性質が異なる、本リポジトリで初めての
#   「pip venv 管理サービス」パターンです。
#
# 実行ユーザー: DynamicUser ではなく固定システムユーザー (discord-bot と同じ)。
#   comfyui-setup (venv 構築) と comfyui (本体) の 2 ユニットが同じ
#   ディレクトリを読み書きします。DynamicUser だと呼び出しごとに UID が
#   変わり、ユニットをまたいだアクセス権の整合が面倒になります
#   (ollama/victoriametrics は単一ユニットだけがデータに触るので
#   この問題が起きません)。固定ユーザーなら普通のパーミッションで済むため、
#   こちらを選びました。ディレクトリの所有権は下の systemd.tmpfiles.rules で
#   宣言的に揃えています。
#
# データ配置: dpool の専用データセットを /var/lib/comfyui にマウント
#   (disko/default.nix 参照)。チェックポイントは肥大化しやすく、rpool
#   (single vdev, 冗長性なし) を圧迫させたくないための判断です。
#   Minecraft を rpool に置いている理由 (SMR HDD での書き込み watchdog stall)
#   とは I/O 特性が異なる (大容量・低頻度・非リアルタイム) ため dpool でも
#   問題ないという判断ですが、チェックポイント読み込みが多少遅くなる
#   可能性はトレードオフとして残ります。
#
# GPU 割り当てと VRAM 衝突ガード:
#   GPU1 (RTX 3060 Ti, 8GiB, FP16 テンソルコアあり) に固定します。
#   GPU 番号は CUDA_DEVICE_ORDER=PCI_BUS_ID の並び (bus 04/06) です。
#   2026-08-11 に GT1030 を bus 05 (表示専任) へ増設した際は 3060 Ti の
#   index が 1 から 2 に繰り下がっていましたが、2026-08-12 に GT1030 を撤去した
#   ため index 1 に戻っています。
#   ollama もこの GPU を優先的に使います (modules/ollama.nix の
#   CUDA_VISIBLE_DEVICES="1,0")。VRAM を分離する仕組みがこのホストには
#   無いため、同時に重い処理が走ると CUDA out of memory どころか
#   NVIDIA ドライバの Xid エラーで GPU ごと wedge し、そのGPUを使う
#   全プロセスが固まる (最悪サーバ全体のハングに近い症状になる) リスクが
#   あります。
#
#   **2026-08-25 にプロジェクター投影用の HDMI もこのカードへ繋ぎ変えました**
#   (1660 SUPER → 3060 Ti、modules/desktop.nix)。投影中は X (Xorg) の VRAM
#   消費もこの GPU に乗るため、ollama/Comfy との衝突リスクが従来より上がって
#   います。下記ガードは使用率ベースのチェックなので X の消費分も検知は
#   しますが、閾値に達しやすくなる点は変わりません。「衝突するくらいなら
#   Comfy を止める」方針で:
#
#     - comfyui-vram-guard (pre-start): 起動前に GPU1 (3060 Ti) の使用率を見て、
#       既に高ければ起動を拒否する (ollama がロード中なら Comfy は動かさない)。
#     - comfyui-vram-guard (watch, 30秒毎): 実行中に使用率が危険域に達するか
#       直近に Xid エラーが出ていたら、フラグを立てたうえで
#       comfyui.service を強制停止する (生成中のジョブは中断される)。
#     - comfyui-vram-resume (30秒毎、常時稼働): フラグが立っていて GPU
#       使用率が十分下がっていれば comfyui.service を自動で再開する。
#       人間が手動で `systemctl stop comfyui` した場合はフラグが立たないため、
#       この機構は関与しません (意図した停止を上書きしません)。
#
#   しきい値 (85% / 95% / 70%) は初期値です。頻繁な誤検知やフラッピングが
#   起きるなら調整してください。
#
# 未検証のリスク (実機での動作確認が必須):
#   pip の torch wheel は CUDA runtime を自前で同梱するため、システム側で
#   必要なのはドライバの libcuda.so / libnvidia-ml.so だけのはずで、
#   LD_LIBRARY_PATH で /run/opengl-driver/lib (hardware.nvidia が提供) を
#   渡しています。ただし opencv-python 等の他の pip 依存が libGL.so.1 の
#   ような非同梱のシステムライブラリを要求してくる可能性があり、その場合は
#   同じ LD_LIBRARY_PATH に該当する nixpkgs パッケージ (pkgs.libGL 等) を
#   追加してください。それでも解決しなければ buildFHSEnv/nix-ld による
#   ラッパー化を検討しますが、今回は実装していません。
#   つまり最初の nixos-rebuild switch → 実際の生成テストで一発成功する
#   保証はなく、最低 1 回はデバッグの反復が必要になる可能性が高いです。
##############################################################################

let
  port = 8188;
  stateDir = "/var/lib/comfyui";
  gpuIndex = "1"; # RTX 3060 Ti (GT1030 撤去により index 2→1 に戻った。投影用 HDMI も同カード、modules/gpu.nix 参照)

  # VRAM 使用率のしきい値 (%)。ヒステリシスで境界値付近のフラッピングを防ぐ。
  startBlockPct = 85; # 起動前チェック: これ以上なら起動を拒否
  stopPct = 95;        # 常時監視: これ以上なら強制停止
  resumePct = 70;      # 自動再開: これ未満になったら再開

  flagDir = "/run/comfyui-vram-guard";
  flagFile = "${flagDir}/stopped-by-guard";

  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";

  usagePctScript = ''
    ${nvidiaSmi} --query-gpu=memory.used,memory.total \
      --format=csv,noheader,nounits -i ${gpuIndex} \
      | awk -F', *' '{ printf "%d", ($1 / $2) * 100 }'
  '';

  vramGuard = pkgs.writeShellApplication {
    name = "comfyui-vram-guard";
    runtimeInputs = [ pkgs.gawk pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
    text = ''
      set -euo pipefail

      mode="''${1:?usage: comfyui-vram-guard pre-start|watch}"

      pct=$(${usagePctScript})

      has_recent_xid() {
        journalctl -k --since "-1min" --no-pager 2>/dev/null | grep -qi "Xid"
      }

      case "$mode" in
        pre-start)
          if [ "$pct" -ge ${toString startBlockPct} ]; then
            echo "comfyui-vram-guard: GPU${gpuIndex} used ''${pct}%% (>= ${toString startBlockPct}%%), refusing to start" >&2
            exit 1
          fi
          ;;
        watch)
          if [ "$pct" -ge ${toString stopPct} ] || has_recent_xid; then
            echo "comfyui-vram-guard: GPU${gpuIndex} used ''${pct}%%, stopping comfyui.service" >&2
            mkdir -p "${flagDir}"
            touch "${flagFile}"
            systemctl stop comfyui.service
          fi
          ;;
        *)
          echo "unknown mode: $mode" >&2
          exit 1
          ;;
      esac
    '';
  };

  vramResume = pkgs.writeShellApplication {
    name = "comfyui-vram-resume";
    runtimeInputs = [ pkgs.gawk pkgs.systemd pkgs.coreutils ];
    text = ''
      set -euo pipefail

      [ -e "${flagFile}" ] || exit 0

      pct=$(${usagePctScript})

      if [ "$pct" -lt ${toString resumePct} ]; then
        rm -f "${flagFile}"
        systemctl start comfyui.service
      fi
    '';
  };
in
{
  ############################################################################
  # 実行ユーザー (discord-bot と同じ固定システムユーザーのパターン)
  ############################################################################
  users.users.comfyui = {
    isSystemUser = true;
    group = "comfyui";
    home = stateDir;
  };
  users.groups.comfyui = { };

  # データセットのマウント直後は root 所有のままなので、宣言的に揃える。
  # 'd' タイプは既存ディレクトリの所有権/モードを直すだけで、中身は消しません。
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 comfyui comfyui - -"
  ];

  ############################################################################
  # venv 構築 (comfy-cli のインストールと ComfyUI 本体の導入)
  #
  # 冪等: venv が無ければ作り、comfy-cli 自体は毎回 -U で更新し、
  # ComfyUI 本体は main.py が無い場合だけ install する。
  ############################################################################
  systemd.services.comfyui-setup = {
    description = "ComfyUI venv setup (comfy-cli)";
    before = [ "comfyui.service" ];

    # comfy-cli は GitPython (workspace_manager.py) を import 時に読み込み、
    # `git` 実行ファイルが PATH に無いと ImportError で即死する
    # (n8n.nix の node PATH 注入と同種の問題)。
    path = [ pkgs.git ];

    # install 時にも torch の CUDA 検出が走るため、本体と同じライブラリ補完と
    # GPU 列挙順の固定が要る (下の comfyui.service の環境変数コメント参照)。
    environment = {
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      CUDA_VISIBLE_DEVICES = gpuIndex;
      LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ] + ":/run/opengl-driver/lib";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "comfyui";
      Group = "comfyui";
      WorkingDirectory = stateDir;
    };

    script = ''
      set -euo pipefail

      if [ ! -x ${stateDir}/venv/bin/python ]; then
        ${pkgs.uv}/bin/uv venv --python ${pkgs.python3}/bin/python3 ${stateDir}/venv
      fi

      ${pkgs.uv}/bin/uv pip install --python ${stateDir}/venv/bin/python -U comfy-cli

      if [ ! -f ${stateDir}/ComfyUI/main.py ]; then
        ${stateDir}/venv/bin/comfy --workspace ${stateDir}/ComfyUI --skip-prompt install --nvidia
      fi

      # ★ 実機で踏んだ罠 (1) ★
      #   comfy install が ComfyUI 用に作る venv (ComfyUI/.venv) は uv venv の
      #   流儀で pip を含まない。ComfyUI-Manager 同梱の manager_util.get_pip_cmd()
      #   は「python -m pip」を最優先で試すため、pip が無いとそこで失敗する。
      if ! ${stateDir}/ComfyUI/.venv/bin/python -m pip --version >/dev/null 2>&1; then
        ${stateDir}/ComfyUI/.venv/bin/python -m ensurepip --upgrade
      fi

      # ★ 実機で踏んだ罠 (2) — 本命 ★
      #   ComfyUI-Manager の config.ini が無い初回起動時、read_config() は
      #   例外を握りつぶして use_uv を自動判定する
      #   (manager_core.py: `find_spec("uv") is not None`)。ComfyUI 側の
      #   requirements.txt が pip パッケージの "uv" (PyPI wrapper。中に
      #   manylinux 向けのバイナリを同梱) を venv に引き込むため、この判定は
      #   常に True になり、以後ずっと use_uv=true が config.ini に固定される。
      #   use_uv=true だと ComfyUI-Manager は python -m pip を一切試さず、
      #   ①「python -m uv」(= 上記 PyPI 版の同梱バイナリ、NixOS 非対応の
      #   generic manylinux バイナリで stub-ld に阻まれる) → ②失敗を握りつぶし
      #   PATH 上の素の `uv` (= nixpkgs 版、これ自体は正常) にフォールバック、
      #   という経路を辿るが、実機ではこの②の段階でも
      #   `Command '['uv', 'pip', 'freeze']' returned non-zero exit status 127`
      #   で失敗しており (①の stub-ld 由来の何かが尾を引いていると推測、
      #   完全な原因特定はできていない)、結果として ComfyUI の起動そのものが
      #   毎回落ちていた。pip さえ入れれば直る話ではなく、config.ini に
      #   明示的に use_uv=false を書いて自動判定そのものを封じる必要がある。
      ${pkgs.python3}/bin/python3 -c '
import configparser, os
path = "${stateDir}/ComfyUI/user/__manager/config.ini"
os.makedirs(os.path.dirname(path), exist_ok=True)
c = configparser.ConfigParser()
if os.path.exists(path):
    c.read(path)
if "default" not in c:
    c["default"] = {}
c["default"]["use_uv"] = "false"
with open(path, "w") as f:
    c.write(f)
'
    '';
  };

  ############################################################################
  # 本体
  ############################################################################
  systemd.services.comfyui = {
    description = "ComfyUI server";
    after = [ "comfyui-setup.service" "nvidia-persistenced.service" ];
    wants = [ "comfyui-setup.service" "nvidia-persistenced.service" "comfyui-vram-guard.timer" ];
    requires = [ "comfyui-setup.service" ];
    wantedBy = [ "multi-user.target" ];

    # comfy launch も comfy-cli 経由で workspace_manager.py (GitPython) を
    # 通るため、setup と同じく git が要る。さらに comfy-cli は launch 時に
    # 内部で `uv pip freeze` を PATH 経由 (フルパス指定ではなく) で叩くため、
    # uv も無いと exit 127 で落ちる (実機で確認)。
    #
    # ★ 実機で踏んだ罠 ★
    #   triton はカーネルを都度 C でラップして gcc でコンパイルする
    #   (Python 拡張 .so をビルドする)。venv には C コンパイラが一切
    #   付属しないため `Failed to find C compiler` で落ちる。pkgs.gcc を
    #   PATH に足し、CC 環境変数でも明示する (triton は CC 環境変数を優先参照)。
    path = [ pkgs.git pkgs.uv pkgs.gcc ];

    environment = {
      # ★ 実機で踏んだ罠 ★
      #   nvidia-smi は PCI バス ID 順 (index0=1660 SUPER, index1=3060 Ti) で
      #   番号を振るが、CUDA ランタイムの既定の列挙順は "FASTEST_FIRST"
      #   (速いカードを先に出す) で、これは nvidia-smi の番号と一致しない。
      #   CUDA_VISIBLE_DEVICES = "1" だけを設定したところ、torch が掴んだのは
      #   1660 SUPER だった (実機ログで確認: "Device: cuda:0 NVIDIA GeForce
      #   GTX 1660 SUPER")。CUDA_DEVICE_ORDER=PCI_BUS_ID を明示することで
      #   nvidia-smi と同じ番号付けに強制し、comfyui-vram-guard が
      #   `nvidia-smi -i 1` で見ている GPU と一致させる。
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      CUDA_VISIBLE_DEVICES = gpuIndex;
      # pip の torch は CUDA runtime を自前で同梱するため、当初は
      # ドライバのユーザ空間ライブラリ (/run/opengl-driver/lib) だけで
      # 足りると見込んでいたが、実機で `libstdc++.so.6: cannot open
      # shared object file` で torch._C (ネイティブ拡張) の読み込みに失敗した。
      # NixOS には /usr/lib 相当が無く、pip wheel が期待する libstdc++ が
      # システムに存在しないため。pkgs.stdenv.cc.cc.lib で補う
      # (§3 で想定していた「CUDA 以外の共有ライブラリ不足」の実例)。
      LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ] + ":/run/opengl-driver/lib";

      # ★ 実機で踏んだ罠 ★
      #   triton (torch のカーネル JIT) は libcuda.so の場所を
      #   `/sbin/ldconfig -p` の出力から探す。modules/gpu.nix で
      #   /sbin/ldconfig 自体は用意したが、NixOS は ld.so.cache を
      #   運用しないためキャッシュファイルが存在せず
      #   `Can't open cache file ... No such file or directory` で
      #   結局失敗する。TRITON_LIBCUDA_PATH を設定すると triton は
      #   ldconfig を一切呼ばずこのパスを直接使うため、根本的に迂回できる。
      TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
      CC = "${pkgs.gcc}/bin/gcc";

      # ★ 実機で踏んだ罠 ★
      #   triton はコンパイル後に ptxas (PTX アセンブラ) / cuobjdump / nvdisasm を
      #   呼ぶが、これらは pip の torch/triton には同梱されず、本来は
      #   nvidia-cuda-nvcc (pip) か CUDA toolkit が提供する。このホストには
      #   ドライバ (hardware.nvidia) しか入れていないため、CUDA toolkit の
      #   該当パッケージを明示的に渡す (3 バイナリはそれぞれ別の cudaPackages
      #   派生物: ptxas は cuda_nvcc、cuobjdump/nvdisasm はそれぞれ専用パッケージ)。
      #   allowUnfreePredicate は "cuda" 接頭辞を包括的に許可済み (modules/gpu.nix)。
      TRITON_PTXAS_PATH = "${pkgs.cudaPackages.cuda_nvcc}/bin/ptxas";
      TRITON_CUOBJDUMP_PATH = "${pkgs.cudaPackages.cuda_cuobjdump}/bin/cuobjdump";
      TRITON_NVDISASM_PATH = "${pkgs.cudaPackages.cuda_nvdisasm}/bin/nvdisasm";
    };

    serviceConfig = {
      Type = "simple";
      User = "comfyui";
      Group = "comfyui";
      WorkingDirectory = stateDir;

      # ollama がすでに GPU1 (3060 Ti) を大きく使っていたらそもそも起動しない。
      ExecStartPre = "${vramGuard}/bin/comfyui-vram-guard pre-start";

      # ★ 実機で踏んだ罠 ★
      #   comfy-aimdo (dynamic VRAM offload) は、VRAM に収まらない巨大モデル
      #   (MiniMax H3 のテキストエンコーダ単体で ~15GB など) を 8GB VRAM の
      #   このカードで読ませようとした際、GPU使用率0%・ディスクI/O0・HTTPの
      #   ソケットすら読み取らない完全なハングを起こすことを実機で確認 (2026-08-08)。
      #   上流でも 2026-08-03 以降の regression としてハング/クラッシュが
      #   報告されている (Comfy-Org/ComfyUI#15255)。--disable-dynamic-vram で
      #   機構自体を無効化する。トレードオフとして VRAM に収まらない巨大モデルは
      #   単純に CUDA OOM で失敗するようになる (無限ハングよりは診断しやすい)。
      #   量子化 (GGUF 等) やより小さいモデルを使えば VRAM 内に収まり、この
      #   フラグが無くても動く。
      ExecStart = "${stateDir}/venv/bin/comfy --workspace ${stateDir}/ComfyUI launch -- --listen 0.0.0.0 --port ${toString port} --disable-dynamic-vram";

      # ガードによる `systemctl stop` は「意図的な停止」として扱われるため
      # Restart= の対象外です (systemd の仕様)。ここはクラッシュ時のみの保険。
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  ############################################################################
  # VRAM 衝突ガード — 常時監視 + 起動前チェック
  #
  # timer に PartOf = comfyui.service を付けているので、comfyui.service が
  # 止まれば (ガード自身が止めた場合も含め) この監視も一緒に止まります。
  # comfyui.service 側の wants で、起動時にセットで立ち上がります。
  ############################################################################
  systemd.services.comfyui-vram-guard = {
    description = "Stop comfyui if GPU VRAM contention risks a driver hang";
    partOf = [ "comfyui.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${vramGuard}/bin/comfyui-vram-guard watch";
    };
  };

  systemd.timers.comfyui-vram-guard = {
    description = "Periodic VRAM contention check for comfyui";
    partOf = [ "comfyui.service" ];
    timerConfig = {
      OnActiveSec = "30s";
      OnUnitActiveSec = "30s";
    };
  };

  ############################################################################
  # GPU が空いたら自動再開 — comfyui.service とはライフサイクルを切り離し、
  # 常時稼働させる (フラグが無ければ何もしない)。
  ############################################################################
  systemd.services.comfyui-vram-resume = {
    description = "Resume comfyui once GPU VRAM contention has cleared";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${vramResume}/bin/comfyui-vram-resume";
    };
  };

  systemd.timers.comfyui-vram-resume = {
    description = "Periodic check to auto-resume comfyui after a guard stop";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
    };
  };

  ############################################################################
  # 公開範囲: tailscale0 限定 (ollama と同じ方針)。
  # サブパスに非対応な可能性が高いため、Serve への専用ポート追加は
  # modules/reverse-proxy.nix 側で行う (n8n と同じ理由)。
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

  ############################################################################
  # 運用メモ
  #
  #   状態確認:
  #     systemctl status comfyui-setup comfyui comfyui-vram-guard.timer comfyui-vram-resume.timer
  #     journalctl -u comfyui-setup -b   # venv 構築 / install のログ
  #     journalctl -u comfyui -b | grep -i cuda
  #
  #   ガードの動作確認:
  #     手動実行: sudo -u comfyui /nix/store/.../comfyui-vram-guard pre-start
  #     強制停止後にフラグが立っているか: ls /run/comfyui-vram-guard/
  #     手動で systemctl stop comfyui した場合はフラグが立たず、
  #     comfyui-vram-resume は何もしないはず。
  #
  #   モデル置き場: /var/lib/comfyui/ComfyUI/models/
  #     専用データセット (dpool/comfyui, recordsize=1M, compression=off)。
  #     スナップショット・syncoid の複製対象外。消えたら再ダウンロードします。
  ############################################################################
}
