{ config, lib, pkgs, ... }:

##############################################################################
# user の `nix profile` (命令的にインストールしたパッケージ) を Grafana から
# 見えるようにする。
#
# modules/nix-info.nix (= environment.systemPackages) との決定的な違いは、
# profile の中身が **Nix 評価時には分からない** ことです。
# `nix profile install` は switch を経由せず、いつでも profile の世代を
# 増やせるため、nix-info.nix のように「systemPackages が変わると textfile の
# 内容が変わり、switch のたびに systemd が再実行する」という仕掛けが使えません。
# したがってここだけは周期タイマーで manifest を読み直します。
#
# 情報源は profile の manifest.json ただ1つです:
#
#   ~/.local/state/nix/profiles/profile/manifest.json
#
# `nix profile list --json` でも同じ内容が取れますが、それは nix デーモンに
# 評価を投げる分だけ重く、root から他ユーザーの profile を読む用途には
# 向きません (HOME・XDG_STATE_HOME を偽装する必要がある)。manifest.json は
# ただの JSON なので jq だけで完結します。
#
# manifest.json から取れるもの (2026-09-23 に実機で確認):
#   - 要素名          … elements のキー (例 "claude-code")
#   - バージョン      … storePaths[0] の basename から
#                       「32文字のハッシュ-」と「要素名-」を剥がした残り
#                       (例 ".../ag6i0c0...-claude-code-2.1.278" -> "2.1.278")
#   - 追従先チャンネル … originalUrl の末尾
#                       (例 "github:NixOS/nixpkgs/nixos-unstable" -> "nixos-unstable")
#
#   - attrPath        … .attrPath (例 "legacyPackages.x86_64-linux.ccusage")
#
# 更新の有無は、nix-info.nix のように Repology (外部サービス) を経由せず、
# **追従先の nixpkgs を直接引いて**判定します。profile に限ってこれができる
# のは、要素数が二桁少なく (実測 4)、かつ各要素が originalUrl と attrPath を
# 自分で覚えているため、チャンネル全体を評価せず 1 属性だけ引けば済むからです:
#
#   nix eval --raw 'github:NixOS/nixpkgs/nixos-unstable#legacyPackages.x86_64-linux.claude-code.version'
#
# 実測 0.3 秒 (store が温まっている場合)。Repology 方式に対する利点:
#   - 名前のマッチング問題が消える。Repology の "project 名" は upstream 名
#     ベースで nixpkgs の pname と一致しないことがあり、rtk / llmfit のような
#     自前・ニッチなパッケージは追跡対象にすら入りません。
#     attrPath で引けば、そもそも同定の問題が発生しません。
#   - 外部サービスの生死に依存しない。2026-09-23 に repology.org は
#     レジストラのサスペンド (.org の委任先が parkpage 系、A レコードが
#     127.0.0.1) で到達不能になり、systemPackages 側のコレクタは 217 件
#     すべてを「追跡対象外」として報告していました。
#   - バージョンが「その nixpkgs が実際に出す値」そのもの。第三者のクロール
#     結果を介さないので、ズレようがありません。
#
# systemPackages (216 件) 側も 2026-09-23 に同じ direct-eval 方式へ切り替え
# 済みです (modules/nix-info.nix)。属性を1件ずつ引く代わりに、チャンネルごと
# 1回の `nix eval --json <channel>#legacyPackages.x86_64-linux --apply <fn>`
# にまとめて評価します — 実測 216 属性で 0.6 秒程度 (温まった評価キャッシュの
# 場合) と軽く、パッケージ数だけ nix を起動するコストは要りません。
# こちらとの違いは attrPath の取得元です。profile は manifest.json が
# attrPath を自分で覚えていますが、systemPackages の pname はトップレベル
# 属性名と一致しないことが多い (実測: 216 件中トップレベル直下で見つかるのは
# 92 件のみ。残りは kdePackages.* 配下の KDE Plasma コンポーネント等) ため、
# 候補スコープ (kdePackages, libsForQt5, python3Packages 等) × pkgs/pkgs.unstable
# の組み合わせを drvPath 完全一致で総当たりして attrPath を同定しています。
##############################################################################

let
  # node_exporter の textfile collector が読むディレクトリ。
  # modules/nix-info.nix / modules/zfs-snapshot-metrics.nix と同じ場所です。
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # 監視対象のユーザー。profile はユーザーごとに独立しているため、
  # 増やしたければここに足すだけで両方のコレクタが追従します。
  profileUsers = [ "seita" ];

  # ユーザー名 -> profile の manifest.json のパス。
  # ホームディレクトリは users.users.<name>.home を唯一の正として引きます
  # (/home/<name> と決め打ちしない)。
  manifestPathFor = user:
    "${config.users.users.${user}.home}/.local/state/nix/profiles/profile/manifest.json";

  ##############################################################################
  # manifest.json -> "要素名\tバージョン\t追従先ref\tattrPath\toriginalUrl" の TSV。
  # パッケージ一覧のコレクタと更新チェックのコレクタの両方がこれを使うので、
  # バージョンの剥がし方が2箇所でズレません。
  ##############################################################################
  manifestToTsv = pkgs.writeText "nix-profile-manifest-to-tsv.jq" ''
    .elements | to_entries[]
    | .key as $name
    | ((.value.storePaths // [])[0] // "") as $storePath
    # nix の store path のハッシュは常に 32 文字の [a-z0-9]。
    # 長さを固定しないと ^[a-z0-9]+- が貪欲に "...-ccusage-" まで食べてしまい、
    # 要素名との突き合わせができなくなる。
    | ($storePath | split("/") | last | sub("^[a-z0-9]{32}-"; "")) as $base
    | (if ($base | startswith($name + "-")) then
         ($base | ltrimstr($name + "-"))
       else
         # 要素名と store path の pname が食い違う場合 (別名で install した等)
         # は、最初に現れる「-数字」以降をバージョンとみなす。
         ([$base | capture("-(?<v>[0-9][^/]*)$")] | (.[0].v // "unknown"))
       end) as $version
    | (.value.originalUrl // "") as $originalUrl
    | ($originalUrl | split("/") | last) as $ref
    | (.value.attrPath // "") as $attrPath
    | [$name, $version, $ref, $attrPath, $originalUrl] | @tsv
  '';

  # Prometheus のラベル値に紛れ込むと壊れる文字を落とす shell 関数。
  # nix-info.nix の escapeLabel と同じ役割ですが、あちらは Nix 評価時、
  # こちらは実行時に効かせる必要があります。
  sanitizeLabelSh = ''
    sanitize_label() {
      printf '%s' "$1" | tr -d '\\"' | tr '\n' ' '
    }
  '';

  profileCollector = pkgs.writeShellApplication {
    name = "nix-profile-metrics";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nix-profile-packages.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      {
        echo '# HELP nix_profile_collector_ok このユーザーの profile の manifest.json を読めたか (1/0)'
        echo '# TYPE nix_profile_collector_ok gauge'
        echo '# HELP nix_profile_package_info user の nix profile に入っているパッケージ (値は常に1)'
        echo '# TYPE nix_profile_package_info gauge'
        echo '# HELP nix_profile_package_count user の nix profile に入っているパッケージの総数'
        echo '# TYPE nix_profile_package_count gauge'
        echo '# HELP nix_profile_generation 現在アクティブな profile の世代番号'
        echo '# TYPE nix_profile_generation gauge'
        echo '# HELP nix_profile_generation_mtime_seconds 現在アクティブな profile の世代が作られた時刻 (unix秒)'
        echo '# TYPE nix_profile_generation_mtime_seconds gauge'

        ${lib.concatMapStringsSep "\n" (user: ''
          manifest="${manifestPathFor user}"

          if [ ! -r "$manifest" ]; then
            # profile を一度も作っていないユーザーもありうるので、これは異常ではない。
            # 「0 パッケージ」と「読めなかった」を取り違えないよう、count は出さない。
            echo 'nix_profile_collector_ok{user="${user}"} 0'
          else
            echo 'nix_profile_collector_ok{user="${user}"} 1'

            count=0
            while IFS=$'\t' read -r name version ref _attrPath _originalUrl; do
              [ -n "$name" ] || continue
              name=$(sanitize_label "$name")
              version=$(sanitize_label "$version")
              ref=$(sanitize_label "$ref")
              echo "nix_profile_package_info{user=\"${user}\",name=\"$name\",version=\"$version\",channel=\"$ref\"} 1"
              count=$((count + 1))
            done < <(jq -r -f ${manifestToTsv} "$manifest")

            echo "nix_profile_package_count{user=\"${user}\"} $count"

            # profile は profile-N-link への symlink。N が世代番号で、
            # nix profile install / rollback のたびに増減する。
            profileLink="${config.users.users.${user}.home}/.local/state/nix/profiles/profile"
            link=$(readlink "$profileLink" || true)
            generation=''${link#profile-}
            generation=''${generation%-link}
            case "$generation" in
              ""|*[!0-9]*) ;;
              *)
                echo "nix_profile_generation{user=\"${user}\"} $generation"
                # 「いつ入れ替えたか」は manifest.json の mtime では取れない —
                # あれは /nix/store の実体なので常に 1 (epoch+1) に正規化されており、
                # 実際 stat すると 1 が返る (2026-09-23 に実機で確認)。
                # 本物の時刻を持っているのは世代 symlink 自身の lstat mtime。
                gen_mtime=$(stat -c %Y "$(dirname "$profileLink")/$link")
                echo "nix_profile_generation_mtime_seconds{user=\"${user}\"} $gen_mtime"
                ;;
            esac
          fi
        '') profileUsers}

        echo "nix_profile_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      # 書きかけを node_exporter に読まれないよう、textfileDir 上で作ってから rename する。
      staging=$(mktemp "${textfileDir}/.nix-profile-packages.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };

  ##############################################################################
  # 追従先チャンネルの現在のバージョンと突き合わせるコレクタ。
  #
  # systemd unit から nix を呼ぶうえでの前提が3つあります:
  #   - HOME が要る。nix はフレークの評価キャッシュを ~/.cache/nix に置くため、
  #     HOME 未設定だと毎回ゼロから評価し直す (あるいは失敗する)。
  #     StateDirectory で専用のディレクトリを与えています。
  #   - NIX_REMOTE=daemon を明示する。対話シェルでは環境から入りますが、
  #     unit には継承されません。ProtectSystem=strict 下では /nix が
  #     read-only なので、デーモン経由でないとストアに書けません。
  #   - ネットワークが要る (チャンネルの tarball 取得)。
  ##############################################################################
  upstreamCollector = pkgs.writeShellApplication {
    name = "nix-profile-upstream-metrics";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nix-profile-upstream-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      # originalUrl -> 解決済みかどうか。同じチャンネルを何度も再解決しない。
      declare -A channel_done=()

      {
        echo '# HELP nix_profile_package_upstream_known 追従先チャンネルからこのパッケージの version を引けたか (1/0)'
        echo '# TYPE nix_profile_package_upstream_known gauge'
        echo '# HELP nix_profile_package_upstream_version_info 追従先チャンネルの現在のバージョン (値は常に1)'
        echo '# TYPE nix_profile_package_upstream_version_info gauge'
        echo '# HELP nix_profile_package_outdated 追従先チャンネルのバージョンと、いま入っているバージョンが違うか (1 = 違う。nix profile upgrade で上がる)'
        echo '# TYPE nix_profile_package_outdated gauge'
        echo '# HELP nix_profile_channel_resolve_ok 追従先チャンネルの現在の revision を解決できたか (1/0)'
        echo '# TYPE nix_profile_channel_resolve_ok gauge'
        echo '# HELP nix_profile_channel_revision_info 追従先チャンネルがいま指している nixpkgs revision (値は常に1)'
        echo '# TYPE nix_profile_channel_revision_info gauge'

        ${lib.concatMapStringsSep "\n" (user: ''
          manifest="${manifestPathFor user}"

          if [ -r "$manifest" ]; then
            while IFS=$'\t' read -r name installed_version ref attrPath originalUrl; do
              [ -n "$name" ] || continue
              name=$(sanitize_label "$name")
              installed_version=$(sanitize_label "$installed_version")
              ref=$(sanitize_label "$ref")

              if [ -z "$attrPath" ] || [ -z "$originalUrl" ]; then
                # manifest に attrPath / originalUrl が無い要素
                # (古い形式で入れたもの、store path 直指定など) は引きようがない。
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 0"
                continue
              fi

              # チャンネルの現在位置を1回だけ解決する。
              # --refresh を付けないと tarball-ttl (既定1時間) のキャッシュで
              # 古い評価を掴み、「更新なし」と誤報告しうる。
              if [ -z "''${channel_done[$originalUrl]+set}" ]; then
                channel_done[$originalUrl]=1
                if meta=$(nix flake metadata --json --refresh "$originalUrl" 2>/dev/null); then
                  echo "nix_profile_channel_resolve_ok{channel=\"$ref\"} 1"
                  rev=$(echo "$meta" | jq -r '.locked.rev // empty')
                  if [ -n "$rev" ]; then
                    rev=$(sanitize_label "$rev")
                    echo "nix_profile_channel_revision_info{channel=\"$ref\",rev=\"$rev\"} 1"
                  fi
                else
                  # 解決に失敗した場合、この後の nix eval は古いキャッシュを
                  # 使う可能性がある。誤報告を黙って出さないよう、
                  # resolve_ok=0 をダッシュボード側で見えるようにしている。
                  echo "nix_profile_channel_resolve_ok{channel=\"$ref\"} 0"
                fi
              fi

              # ここでは --refresh を付けない。直前の flake metadata --refresh が
              # 同じ originalUrl のキャッシュを更新済みで、二重に取りに行く意味がない。
              if upstream_version=$(nix eval --raw "''${originalUrl}#''${attrPath}.version" 2>/dev/null) \
                && [ -n "$upstream_version" ]; then
                upstream_version=$(sanitize_label "$upstream_version")
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 1"
                echo "nix_profile_package_upstream_version_info{user=\"${user}\",name=\"$name\",version=\"$upstream_version\"} 1"
                if [ "$upstream_version" = "$installed_version" ]; then
                  echo "nix_profile_package_outdated{user=\"${user}\",name=\"$name\"} 0"
                else
                  echo "nix_profile_package_outdated{user=\"${user}\",name=\"$name\"} 1"
                fi
              else
                # 属性が消えた (rename / removal) か、評価に失敗した。
                # どちらも「更新なし」ではないので outdated は出さない。
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 0"
              fi
            done < <(jq -r -f ${manifestToTsv} "$manifest")
          fi
        '') profileUsers}

        echo "nix_profile_upstream_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      staging=$(mktemp "${textfileDir}/.nix-profile-upstream-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"

    # profile 側を Repology から direct-eval へ移したときの旧出力。
    # 書き手がいなくなっても textfile collector は *.prom を読み続けるため、
    # 明示的に消さないと死んだメトリクスが配られ続ける (実機で確認)。
    "r ${textfileDir}/nix-profile-repology-status.prom - - - -"
  ];

  ##############################################################################
  # profile の中身: `nix profile install` は switch を経由しないため、
  # nix-info.nix のような「switch で自動再実行」が使えない。周期タイマーで見る。
  # manifest.json を1つ読むだけなので 15 分おきでも負荷は無視できる。
  #
  # ProtectHome は true にできない — 見に行く先がまさにユーザーのホームのため。
  # 代わりに read-only にして、profile 配下を書き換える事故を防ぐ。
  ##############################################################################
  systemd.services.nix-profile-metrics = {
    description = "user の nix profile の内容を node_exporter の textfile として出力する";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe profileCollector;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.nix-profile-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
      RandomizedDelaySec = "1min";
      Persistent = true;
    };
  };

  ##############################################################################
  # 追従先チャンネルとの突き合わせ: 1 要素あたり nix eval 1回 (実測 0.3 秒)。
  # チャンネル自体は1日に数回しか動かないので1日1回で十分。
  #
  # ProtectSystem=strict 下でも動かすため、HOME を StateDirectory に逃がし、
  # NIX_REMOTE=daemon を明示してストア操作をデーモンに任せています。
  ##############################################################################
  systemd.services.nix-profile-upstream-metrics = {
    description = "user の nix profile のパッケージ更新有無 (追従先 nixpkgs と直接比較) を node_exporter の textfile として出力する";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe upstreamCollector;
      # チャンネルの tarball を取り直す場合があるので余裕を取る。
      TimeoutStartSec = "30min";
      StateDirectory = "nix-profile-upstream";
      Environment = [
        "HOME=/var/lib/nix-profile-upstream"
        "NIX_REMOTE=daemon"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      # AF_UNIX は nix デーモンのソケット、AF_INET/6 はチャンネルの取得。
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.nix-profile-upstream-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "12min";
      OnUnitActiveSec = "24h";
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };

  ##############################################################################
  # 動作確認
  #
  #   systemctl start nix-profile-metrics nix-profile-upstream-metrics
  #   cat /var/lib/prometheus-node-exporter-text-files/nix-profile-packages.prom
  #   cat /var/lib/prometheus-node-exporter-text-files/nix-profile-upstream-status.prom
  #   curl -s localhost:9100/metrics | grep '^nix_profile_'
  ##############################################################################
}
