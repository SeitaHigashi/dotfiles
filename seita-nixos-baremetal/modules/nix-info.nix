{ config, lib, pkgs, ... }:

##############################################################################
# 「今このマシンに何が入っているか」を Grafana から見えるようにする。
#
# 2つの関心事を1つのモジュールにまとめています:
#
#   1. インストール済みパッケージ一覧 (environment.systemPackages)
#      Nix 式の評価時点で確定する情報なので、bash でパースせず Nix 側で
#      直接 name/version のペアに変換して textfile に焼きます。
#      systemPackages が変わると生成される textfile の中身 (= 呼び出す
#      スクリプトのハッシュ) が変わるため、switch のたびに systemd が
#      ユニットの変化を検知して自動的に再実行します。周期タイマーは不要です。
#
#   2. 使っている nixpkgs revision が Hydra (hydra.nixos.org) でどう
#      評価されているか。flake.lock の rev が「最近の評価一覧」に
#      現れているかと、最後に評価された時刻を見ます。
#      個々のインストール済みパッケージを Hydra 上のジョブ名に対応させる
#      のは現実的ではありません (全パッケージが個別ジョブを持つわけではなく、
#      数百パッケージ分のリクエストになるため)。代わりに「使っている
#      nixpkgs/nixos チャンネルが Hydra で評価され続けているか」という
#      チャンネル単位の健全性を見ます。
#
#   3. パッケージ単位で「新しいバージョンが出ているか」。
#      正確にやるなら最新の nixpkgs 全体を評価してバージョンを比較する
#      必要がありますが、それは家庭用サーバーで定期実行するには重すぎます。
#      代わりに Repology (https://repology.org) の公開 API を使います。
#      Repology は各ディストリのパッケージ一覧を継続的にクロールしており、
#      nixpkgs の stable/unstable チャンネルも "nix_stable_25_05" /
#      "nix_unstable" という名前で追跡対象に入っています。
#      パッケージ名で問い合わせて、Repology が把握している現在のチャンネル内
#      バージョンと、いま入っているバージョンを比較するだけなので、
#      nixpkgs を評価し直す必要がありません。
#      ただし Repology の "project 名" は upstream 名ベースで、必ずしも
#      nixpkgs の pname と一致しません (特に Multica や opencode のような
#      自前/ニッチなパッケージは追跡対象外)。一致しないものは「不明」として
#      扱い、「更新可能」と誤判定しないようにしています。
#      API のレート制限 (1 req/秒) を守るため、パッケージ数だけ問い合わせる
#      このジョブは1日1回にしています。
##############################################################################

let
  # node_exporter の textfile collector が読むディレクトリ。
  # modules/monitoring.nix の extraFlags、modules/zfs-snapshot-metrics.nix と
  # 同じ場所です。
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Prometheus のラベル値としてそのまま埋め込めるようにエスケープする。
  # パッケージ名に " や \ が来ることは通常ありませんが念のため。
  escapeLabel = s:
    lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" " " ] s;

  # flake.lock の nixpkgs input の ref ("nixos-25.05") から Repology の
  # リポジトリ名 ("nix_stable_25_05") を機械的に導く。stateVersion とは別物
  # (CLAUDE.md 参照) で、flake.nix 側で追従先ブランチが変わることがあるため
  # 決め打ちにせず、ここで一度だけ計算します。
  flakeLock = builtins.fromJSON (builtins.readFile ../flake.lock);
  stableChannelRef = flakeLock.nodes.nixpkgs.original.ref; # 例: "nixos-25.05"
  stableRepologyRepo =
    "nix_stable_" + lib.replaceStrings [ "." ] [ "_" ]
      (lib.removePrefix "nixos-" stableChannelRef);

  # そのパッケージが modules/unstable.nix 経由 (pkgs.unstable.*) で入っているかを
  # 「pkgs.unstable 側の同名属性と drvPath が完全一致するか」で機械的に判定する。
  # unstable.nix のリストを二重管理しないためにこうしています —
  # unstable 由来のパッケージを stable チャンネルと比較すると、常に
  # 「更新可能」という誤判定になってしまうため (実測: neovim/brave/ollama 等で発生)。
  # バージョン文字列の一致では判定しません — bzip2/gzip/sudo のように
  # stable と unstable でたまたま同じバージョンのまま止まっているパッケージが
  # 誤って unstable 扱いになったため (実測)。drvPath ならビルドの元が
  # 本当に同じ nixpkgs revision かどうかまで見るので誤検知しません。
  #
  # 削除されたエイリアス (例: libsForQt5.kio-admin) は属性としては存在しつつ
  # 参照した瞬間に throw するため、tryEval で握りつぶす。
  isFromUnstable = p:
    let
      pname = p.pname or p.name or null;
      attempt =
        if pname == null then { success = false; }
        else builtins.tryEval (pkgs.unstable.${pname}.drvPath or null);
    in
    attempt.success && attempt.value != null && attempt.value == (p.drvPath or null);

  # name/version/repology のリポジトリ名 のタプルが唯一の正。textfile 用の行と、
  # Repology 問い合わせ用の TSV は両方ともここから作るので、パッケージの
  # 数え方が2箇所でズレません。
  packages = lib.unique (map
    (p: {
      name = escapeLabel (p.pname or p.name or "unknown");
      version = escapeLabel (p.version or "unknown");
      repologyRepo = if isFromUnstable p then "nix_unstable" else stableRepologyRepo;
    })
    (lib.filter lib.isDerivation config.environment.systemPackages));

  packageLines = map
    (p: ''nixos_installed_package_info{name="${p.name}",version="${p.version}"} 1'')
    packages;

  packagesProm = pkgs.writeText "nixos-packages.prom" ''
    # HELP nixos_installed_package_info environment.systemPackages に列挙されているパッケージ (値は常に1)
    # TYPE nixos_installed_package_info gauge
    ${lib.concatStringsSep "\n" packageLines}
    # HELP nixos_installed_package_count environment.systemPackages に列挙されているパッケージの総数
    # TYPE nixos_installed_package_count gauge
    nixos_installed_package_count ${toString (lib.length packageLines)}
  '';

  # Repology 問い合わせ用: 1行 "name\tversion\trepologyのリポジトリ名"。
  # unstable 由来のパッケージは nix_unstable、それ以外は stableRepologyRepo と
  # 比較先が変わるので、行ごとに持たせる。
  packageNamesVersionsTsv = pkgs.writeText "nixos-package-names-versions.tsv"
    (lib.concatMapStringsSep "\n" (p: "${p.name}\t${p.version}\t${p.repologyRepo}") packages);

  # flake.lock の nixpkgs (stable) / nixpkgs-unstable の revision。
  # machine.nix と同じく「値の置き場は1つ」の原則に従い、ここでも読み直さず
  # flake.lock をそのまま読みます (flakeLock 自体は上で定義済み)。
  stableRev = flakeLock.nodes.nixpkgs.locked.rev;
  unstableRev = flakeLock.nodes."nixpkgs-unstable".locked.rev;

  # channel 名 -> "project/jobset 使っているrev" の対応。
  # nixos-25.05 は NixOS 全体のリリースブランチ (nixos/release-25.05-small)、
  # nixos-unstable は nixpkgs の master ブランチ評価 (nixpkgs/unstable) に
  # 対応させています。後者は nixos-unstable チャンネル自体 (テスト通過後の
  # 絞り込み) とは厳密には別物ですが、そこから枝分かれする直前の評価なので
  # 「Hydra がこの内容を最近評価しているか」の指標としては十分です。
  hydraChannels = {
    "nixos-25.05" = { jobset = "nixos/release-25.05-small"; rev = stableRev; };
    "nixos-unstable" = { jobset = "nixpkgs/unstable"; rev = unstableRev; };
  };

  hydraCollector = pkgs.writeShellApplication {
    name = "hydra-build-metrics";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/hydra-build-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      {
        echo "# HELP hydra_channel_last_eval_timestamp_seconds Hydra が最後にこのジョブセットを評価した時刻 (unix秒)"
        echo "# TYPE hydra_channel_last_eval_timestamp_seconds gauge"
        echo "# HELP hydra_pinned_revision_evaluated flake.lock の revision が直近の評価一覧に見つかったか (1/0)"
        echo "# TYPE hydra_pinned_revision_evaluated gauge"
        echo "# HELP hydra_fetch_ok このチャンネルの Hydra API 問い合わせが成功したか (1/0)"
        echo "# TYPE hydra_fetch_ok gauge"

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (channel: c: ''
            if json=$(curl -fsS -m 20 -H "Accept: application/json" "https://hydra.nixos.org/jobset/${c.jobset}/evals" 2>/dev/null); then
              echo 'hydra_fetch_ok{channel="${channel}"} 1'
              ts=$(echo "$json" | jq -r '.evals[0].timestamp // empty')
              if [ -n "$ts" ]; then
                echo "hydra_channel_last_eval_timestamp_seconds{channel=\"${channel}\"} $ts"
              fi
              found=$(echo "$json" | jq -r '([.evals[].jobsetevalinputs.nixpkgs.revision] | index("${c.rev}")) != null')
              if [ "$found" = "true" ]; then
                echo 'hydra_pinned_revision_evaluated{channel="${channel}"} 1'
              else
                echo 'hydra_pinned_revision_evaluated{channel="${channel}"} 0'
              fi
            else
              echo 'hydra_fetch_ok{channel="${channel}"} 0'
            fi
          '')
          hydraChannels)}

        echo "hydra_build_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      # zfs-snapshot-metrics.nix と同じく、書きかけを読まれないよう
      # textfileDir 上で作ってから rename する。
      staging=$(mktemp "${textfileDir}/.hydra-build-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };

  repologyCollector = pkgs.writeShellApplication {
    name = "repology-package-metrics";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ];
    text = ''
      out="${textfileDir}/repology-package-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # Repology は識別可能な User-Agent を求めており (匿名だと 403)、
      # かつ 1 req/秒程度に抑えるようお願いしています。
      # パッケージ数だけ順に叩くのでここで律速しています。
      ua="nixos-home-dashboard/1.0 (personal homelab textfile collector)"

      {
        echo '# HELP nixos_package_repology_known Repology に、対応するチャンネル (unstable 由来なら nix_unstable、それ以外は使用中の stable チャンネル) 上でこの名前のパッケージが見つかったか (1/0)'
        echo '# TYPE nixos_package_repology_known gauge'
        echo '# HELP nixos_package_repology_outdated Repology 上の対応チャンネルのバージョンと、いま入っているバージョンが違うか (1 = 違う。flake update で上がる可能性がある)'
        echo '# TYPE nixos_package_repology_outdated gauge'
        echo '# HELP nixos_package_repology_version_info Repology が報告している対応チャンネルでのバージョン (値は常に1)'
        echo '# TYPE nixos_package_repology_version_info gauge'

        while IFS=$'\t' read -r name installed_version repo; do
          sleep 1

          if ! json=$(curl -fsS -m 10 -H "Accept: application/json" -H "User-Agent: $ua" \
            "https://repology.org/api/v1/project/''${name}" 2>/dev/null); then
            # 問い合わせ自体の失敗 (レート制限・タイムアウト等) は
            # 「追跡対象外」と区別せず、単に known=0 として静かにスキップする。
            echo "nixos_package_repology_known{name=\"''${name}\"} 0"
            continue
          fi

          repology_version=$(echo "$json" | jq -r --arg repo "$repo" --arg name "$name" \
            '[.[] | select(.repo == $repo and (.srcname == $name or .binname == $name))][0].version // empty')

          if [ -z "$repology_version" ]; then
            echo "nixos_package_repology_known{name=\"''${name}\"} 0"
            continue
          fi

          # ラベル値に紛れ込む可能性のある引用符・バックスラッシュを落とす
          # (通常のバージョン文字列には出てこないが念のため)。
          repology_version=$(printf '%s' "$repology_version" | tr -d '\\"')

          echo "nixos_package_repology_known{name=\"''${name}\"} 1"
          echo "nixos_package_repology_version_info{name=\"''${name}\",version=\"''${repology_version}\"} 1"
          if [ "$repology_version" = "$installed_version" ]; then
            echo "nixos_package_repology_outdated{name=\"''${name}\"} 0"
          else
            echo "nixos_package_repology_outdated{name=\"''${name}\"} 1"
          fi
        done < ${packageNamesVersionsTsv}

        echo "repology_package_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      staging=$(mktemp "${textfileDir}/.repology-package-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];

  ##############################################################################
  # パッケージ一覧: 周期タイマーなし。中身は Nix 評価時に確定しているため、
  # switch のたびに (中身が変わっていれば) systemd が再実行する。
  ##############################################################################
  systemd.services.nixos-package-metrics = {
    description = "インストール済みパッケージ一覧を node_exporter の textfile として出力する";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nixos-package-metrics" ''
        set -euo pipefail
        staging=$(mktemp "${textfileDir}/.nixos-packages.XXXXXX")
        cat ${packagesProm} > "$staging"
        chmod 0444 "$staging"
        mv -f "$staging" "${textfileDir}/nixos-packages.prom"
      '';
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  ##############################################################################
  # Hydra ビルド状況: 外部 API (hydra.nixos.org) への問い合わせなので、
  # ネットワークが要る (zfs-snapshot-metrics.nix の AF_UNIX 縛りとは違う)。
  # チャンネルは頻繁には動かないので 6 時間おきで十分。
  ##############################################################################
  systemd.services.hydra-build-metrics = {
    description = "使用中の nixpkgs revision の Hydra ビルド状況を node_exporter の textfile として出力する";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe hydraCollector;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.hydra-build-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "5min";
      Persistent = true;
    };
  };

  ##############################################################################
  # Repology 経由のパッケージ更新チェック: パッケージ数だけ 1 req/秒で
  # 順に問い合わせるため 200 パッケージ超で数分かかる。頻繁に動かす意味も
  # 薄い (upstream のリリース頻度はそんなに速くない) ので1日1回。
  ##############################################################################
  systemd.services.repology-package-metrics = {
    description = "インストール済みパッケージの更新有無 (Repology 経由) を node_exporter の textfile として出力する";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe repologyCollector;
      # パッケージ数 x 1秒 + 通信分。デフォルトの 90秒では確実に間に合わない。
      TimeoutStartSec = "30min";
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.repology-package-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "24h";
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };

  ##############################################################################
  # 動作確認
  #
  #   systemctl start nixos-package-metrics hydra-build-metrics repology-package-metrics
  #   cat /var/lib/prometheus-node-exporter-text-files/nixos-packages.prom
  #   cat /var/lib/prometheus-node-exporter-text-files/hydra-build-status.prom
  #   cat /var/lib/prometheus-node-exporter-text-files/repology-package-status.prom
  #   curl -s localhost:9100/metrics | grep -E '^(nixos_installed|nixos_package_repology|hydra_)'
  #
  #   repology-package-metrics は1回の実行に数分かかるので気長に待つこと。
  ##############################################################################
}
