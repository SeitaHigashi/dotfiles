{ config, lib, pkgs, ... }:

##############################################################################
# 「今このマシンに何が入っているか」を Grafana から見えるようにする。
#
# 3つの関心事を1つのモジュールにまとめています:
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
#      以前は Repology (https://repology.org) の公開 API で判定していましたが、
#      2026-09-23 に repology.org がレジストラのサスペンドで恒久的に到達不能に
#      なりました (DNS A レコードが 127.0.0.1、TCP 接続も拒否される — レート
#      制限ではなくドメイン自体の失効)。そのため直接 `nix eval` で追従先
#      nixpkgs を評価する方式に切り替えています。仕組みは
#      modules/nix-profile-info.nix の upstreamCollector と同じで、こちらは
#      対象パッケージが2桁多い (実測 216) 分だけ以下の2点を追加しています:
#
#      a. attrPath の同定を Repology の名前マッチングではなく drvPath の
#         完全一致で行う。systemPackages の pname は必ずしも nixpkgs の
#         トップレベル属性名と一致しません (実測: 216 件中トップレベル直下で
#         見つかるのは 92 件のみ。残りの大半は kdePackages.* 配下の KDE
#         Plasma コンポーネント — dolphin, kwin, kio, konsole, baloo,
#         breeze 等 — と glibc の複数出力パッケージ getconf-glibc-*,
#         getent-glibc-*, glibc-locales)。そこで候補スコープ
#         (トップレベル, kdePackages, libsForQt5, plasma5Packages,
#         python3Packages, nodePackages) × 候補ベース (pkgs, pkgs.unstable) の
#         各組み合わせで `<base>.<scope>.<pname>.drvPath` を tryEval しつつ
#         引き、実際にインストールされている派生物の drvPath と一致した
#         ものだけを採用します。削除されたエイリアス (例:
#         libsForQt5.kio-admin) は属性としては存在しつつ参照した瞬間に
#         throw するため、tryEval で握りつぶします。一致したベースが
#         pkgs.unstable なら追従先は nixos-unstable、pkgs なら
#         flake.lock 由来の stable チャンネルという判定も、この drvPath
#         一致でそのまま兼ねています (旧 isFromUnstable はここに統合し
#         廃止しました)。一致する候補が無いパッケージは「同定不能」として
#         attr_resolved=0 を出し、更新判定はしません — 名前だけで
#         推測することはしません。
#
#      b. nixpkgs の評価をパッケージ数分ループしない。216 属性を1回の
#         `nix eval --json <channel>#legacyPackages.x86_64-linux --apply
#         <fn>` にまとめて評価すると実測 0.6 秒程度 (warm な評価キャッシュ)
#         で終わります。属性ごとに `nix eval` を起動するとプロセス起動と
#         評価キャッシュの再構築コストが積み上がるため、チャンネルあたり
#         1回のバルク評価に固定しています。attrPath は Nix 側で
#         あらかじめ ["kdePackages" "dolphin"] のようにスコープ・pname に
#         分割した状態で渡し、shell 側や `--apply` 内で文字列分割はしません
#         (分割ロジックを2箇所に持たないため)。
#
#      Repology 方式に対するその他の利点は nix-profile-info.nix のコメントと
#      同じです (外部サービスの生死に依存しない、バージョンが「その nixpkgs
#      が実際に出す値」そのもの)。
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

  # Prometheus のラベル値に紛れ込むと壊れる文字を落とす shell 関数。
  # nix-profile-info.nix の sanitizeLabelSh と同じ役割で、あちらは実行時に
  # 取得した値 (revision, version) に対して効かせる必要があるため shell 側にも
  # 同じものを持っています。
  sanitizeLabelSh = ''
    sanitize_label() {
      printf '%s' "$1" | tr -d '\\"' | tr '\n' ' '
    }
  '';

  # flake.lock の nixpkgs input の ref ("nixos-25.05") を唯一の正として読む。
  # stateVersion とは別物 (CLAUDE.md 参照) で、flake.nix 側で追従先ブランチが
  # 変わることがあるため決め打ちにせず、ここで一度だけ計算します。
  # nixpkgs-unstable 側は flake.nix が意図的に特定 revision に固定しています
  # (長いコメント付き) が、ここで「更新があるか」を見たいのはブランチの
  # 最新 (nixos-unstable) との差分なので、固定 revision ではなくブランチ名を
  # 使います。
  flakeLock = builtins.fromJSON (builtins.readFile ../flake.lock);
  stableChannelRef = flakeLock.nodes.nixpkgs.original.ref; # 例: "nixos-25.05"

  # 追従先チャンネル名 -> flake 参照。実際に使うのは2つだけ
  # (unstable 由来のパッケージ用と stable 由来のパッケージ用)。
  channels = {
    "nixos-unstable" = "github:NixOS/nixpkgs/nixos-unstable";
    ${stableChannelRef} = "github:NixOS/nixpkgs/${stableChannelRef}";
  };

  # attrPath 同定の候補スコープ。トップレベル ("") をまず試し、
  # 見つからなければ KDE Plasma / Python / Node 系のサブセットを順に試す。
  candidateScopes = [ "" "kdePackages" "libsForQt5" "plasma5Packages" "python3Packages" "nodePackages" ];

  # 派生物 p の pname が、base.scope 配下に同じ drvPath で存在するかを
  # tryEval で確かめる。削除されたエイリアスの throw や、スコープ自体が
  # 存在しない場合はすべて「見つからなかった」として扱う。
  candidateFor = tag: base: scope: pname: drvPath:
    let
      scoped =
        if scope == "" then base
        else
          let attempt = builtins.tryEval (base.${scope} or null); in
          if attempt.success then attempt.value else null;
      attempt =
        if scoped == null then { success = false; }
        else builtins.tryEval (scoped.${pname}.drvPath or null);
    in
    if attempt.success && attempt.value != null && attempt.value == drvPath
    then { inherit tag scope; }
    else null;

  # このホストで実際に使っている2つのベース (unstable, stable) それぞれの
  # 全候補スコープを試し、drvPath が一致した最初の1件を採用する。
  # unstable を先に試すのは、modules/unstable.nix 経由のパッケージが
  # 誤って stable 側の同名属性 (別 revision) に一致してしまう余地を無くすため
  # (drvPath 一致なので理論上は起こらないはずだが、優先順位として明示しておく)。
  resolveAttr = p:
    let
      pname = p.pname or p.name or null;
      drvPath = p.drvPath or null;
    in
    if pname == null || drvPath == null then null
    else
      let
        bases = [
          { tag = stableChannelRef; unstable = false; }
          { tag = "nixos-unstable"; unstable = true; }
        ];
        pkgsFor = b: if b.unstable then pkgs.unstable else pkgs;
        candidates = lib.concatMap
          (b: map (scope: candidateFor b.tag (pkgsFor b) scope pname drvPath) candidateScopes)
          bases;
      in
      lib.findFirst (c: c != null) null candidates;

  # name/version/attrPath/追従先チャンネル のタプルが唯一の正。textfile 用の
  # 行と、更新チェック用の TSV は両方ともここから作るので、パッケージの
  # 数え方が2箇所でズレません。
  packages = lib.unique (map
    (p:
      let
        pname = p.pname or p.name or "unknown";
        match = resolveAttr p;
      in
      {
        name = escapeLabel pname;
        version = escapeLabel (p.version or "unknown");
        # attrPath はスコープ+pname を "." で結合した文字列。shell 側では
        # 分割せず、TSV の1フィールドとしてそのまま運ぶだけにする
        # (--apply 関数への分割済みリストの受け渡しは Nix 側で完結させるため)。
        attrPath =
          if match == null then null
          else if match.scope == "" then pname
          else "${match.scope}.${pname}";
        channel = if match == null then null else match.tag;
      })
    (lib.filter lib.isDerivation config.environment.systemPackages));

  packageLines = map
    (p: ''nixos_installed_package_info{name="${p.name}",version="${p.version}"} 1'')
    packages;

  # attrPath 問い合わせは name だけがラベルなので、同じ pname が違う version で
  # 複数回 systemPackages に現れると (実測: fuse 2.9.9 と fuse 3.16.2 が両方入る)
  # 同一ラベルの metric を2回吐いて node_exporter 側で
  # "collected metric ... was collected before with the same name and label
  # values" エラーになる (2026-09-06 に実機の journal で確認、30秒おきに
  # 無限に出続けていた)。name 単位で先勝ちさせて1回だけ扱う。
  packagesByName = lib.attrValues
    (lib.foldl' (acc: p: acc // { ${p.name} = acc.${p.name} or p; }) { } packages);

  packagesProm = pkgs.writeText "nixos-packages.prom" ''
    # HELP nixos_installed_package_info environment.systemPackages に列挙されているパッケージ (値は常に1)
    # TYPE nixos_installed_package_info gauge
    ${lib.concatStringsSep "\n" packageLines}
    # HELP nixos_installed_package_count environment.systemPackages に列挙されているパッケージの総数
    # TYPE nixos_installed_package_count gauge
    nixos_installed_package_count ${toString (lib.length packageLines)}
  '';

  # 更新チェック用: 1行 "name\tversion\tchannel\tattrPath"。
  # attrPath 同定に失敗したパッケージは channel/attrPath が空文字になる。
  packageAttrsTsv = pkgs.writeText "nixos-package-attrs.tsv"
    (lib.concatMapStringsSep "\n"
      (p: "${p.name}\t${p.version}\t${if p.channel == null then "" else p.channel}\t${if p.attrPath == null then "" else p.attrPath}")
      packagesByName);

  # チャンネルごとの attrPath 一覧を、あらかじめ "." で分割したリストの
  # リストとして Nix 側で作る。ドット入り attrPath (例 "kdePackages.dolphin")
  # を shell や --apply 式の中で文字列分割しないための唯一の置き場。
  attrPathPartsForChannel = channel: lib.unique
    (map (p: lib.splitString "." p.attrPath)
      (lib.filter (p: p.channel == channel && p.attrPath != null) packagesByName));

  # 指定チャンネルの legacyPackages に対して `nix eval --apply` で渡す式を
  # 文字列として組み立てる。attrPath は分割済みリストのリストとして埋め込み、
  # 実行時の文字列分割を一切行わない。各属性は tryEval で保護し、
  # (a) スコープ自体が存在しない (b) 削除されたエイリアスで throw する
  # (c) version 属性が無い/文字列でない、のいずれでも空文字列を返すだけで
  # 評価全体を失敗させない。
  mkApplyExpr = channel:
    let
      partsList = attrPathPartsForChannel channel;
      partsToNixList = parts: "[ " + lib.concatMapStringsSep " " (s: builtins.toJSON s) parts + " ]";
      partsListNix = "[ " + lib.concatMapStringsSep " " partsToNixList partsList + " ]";
    in ''
      pkgSet:
      builtins.listToAttrs (map (parts:
        let
          get = builtins.foldl' (acc: k: if acc == null then null else acc.''${k} or null) pkgSet parts;
          got = builtins.tryEval get;
          versionAttempt =
            if got.success && got.value != null
            then builtins.tryEval (got.value.version or null)
            else { success = false; };
          version =
            if versionAttempt.success && builtins.isString versionAttempt.value
            then versionAttempt.value
            else "";
        in
        { name = builtins.concatStringsSep "." parts; value = version; }
      ) ${partsListNix})
    '';

  # 上の式を評価時に textfile として書き出しておく。shellcheck は
  # writeShellApplication のビルド時に ExecStart の中身を静的解析するため、
  # 生の Nix 式 (${...} だらけで shell 変数展開と誤認される) を直接
  # ExecStart 文字列へ埋め込むと SC2016 で弾かれる。ファイルに逃がして
  # 実行時に `cat` で読み込むことで、shellcheck の対象からも外れる。
  applyExprFileFor = channel:
    pkgs.writeText "nixos-package-upstream-apply-${channel}.nix" (mkApplyExpr channel);

  ##############################################################################
  # 追従先チャンネルの現在のバージョンと突き合わせるコレクタ。
  # チャンネルあたり nix 呼び出しは2回だけ (metadata 解決 + バルク評価)。
  #
  # systemd unit から nix を呼ぶうえでの前提は modules/nix-profile-info.nix の
  # upstreamCollector と同じ3つです:
  #   - HOME が要る (評価キャッシュを ~/.cache/nix に置くため)。StateDirectory で
  #     専用のディレクトリを与える。
  #   - NIX_REMOTE=daemon を明示する。ProtectSystem=strict 下では /nix が
  #     read-only なので、デーモン経由でないとストアに書けない。
  #   - ネットワークが要る (チャンネルの tarball 取得)。
  # nix-profile-info.nix と違い、ユーザーの home を読む必要は無いため
  # ProtectHome = true のままにしている。
  ##############################################################################
  upstreamCollector = pkgs.writeShellApplication {
    name = "nixos-package-upstream-metrics";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nixos-package-upstream-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      {
        echo '# HELP nixos_package_upstream_attr_resolved このパッケージの nixpkgs attrPath を drvPath 一致で同定できたか (1/0)'
        echo '# TYPE nixos_package_upstream_attr_resolved gauge'
        echo '# HELP nixos_package_upstream_known 追従先チャンネルからこのパッケージの version を引けたか (1/0)。attr_resolved=0 のものは出力しない'
        echo '# TYPE nixos_package_upstream_known gauge'
        echo '# HELP nixos_package_upstream_version_info 追従先チャンネルの現在のバージョン (値は常に1)'
        echo '# TYPE nixos_package_upstream_version_info gauge'
        echo '# HELP nixos_package_outdated 追従先チャンネルのバージョンと、いま入っているバージョンが違うか (1 = 違う。flake update で上がる可能性がある)。upstream_known=1 のときだけ出力する'
        echo '# TYPE nixos_package_outdated gauge'
        echo '# HELP nixos_channel_resolve_ok 追従先チャンネルの現在の revision を解決できたか (1/0)'
        echo '# TYPE nixos_channel_resolve_ok gauge'
        echo '# HELP nixos_channel_revision_info 追従先チャンネルがいま指している nixpkgs revision (値は常に1)'
        echo '# TYPE nixos_channel_revision_info gauge'

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (channel: channelRef: ''
            # --refresh を付けないと tarball-ttl (既定1時間) のキャッシュで
            # 古い評価を掴み、「更新なし」と誤報告しうる
            # (nix-profile-info.nix と同じ理由)。
            if meta=$(nix flake metadata --json --refresh "${channelRef}" 2>/dev/null); then
              echo 'nixos_channel_resolve_ok{channel="${channel}"} 1'
              rev=$(echo "$meta" | jq -r '.locked.rev // empty')
              if [ -n "$rev" ]; then
                rev=$(sanitize_label "$rev")
                echo "nixos_channel_revision_info{channel=\"${channel}\",rev=\"$rev\"} 1"
              fi
            else
              # 解決に失敗した場合、この後の nix eval は古いキャッシュを
              # 使う可能性がある。誤報告を黙って出さないよう、
              # resolve_ok=0 をダッシュボード側で見えるようにしている。
              echo 'nixos_channel_resolve_ok{channel="${channel}"} 0'
            fi

            # このチャンネルの attrPath をまとめて1回で評価する。
            # 216属性で実測0.6秒程度 (温まった評価キャッシュの場合)。
            # ここでは --refresh を付けない — 直前の flake metadata --refresh が
            # 同じチャンネルのキャッシュを更新済みで、二重に取りに行く意味がない。
            nix eval --json "${channelRef}#legacyPackages.x86_64-linux" \
              --apply "$(cat ${applyExprFileFor channel})" \
              > "$work/versions-${channel}.json" 2>/dev/null || echo '{}' > "$work/versions-${channel}.json"
          '')
          channels)}

        while IFS=$'\t' read -r name installed_version channel attrPath; do
          [ -n "$name" ] || continue
          name=$(sanitize_label "$name")
          installed_version=$(sanitize_label "$installed_version")

          if [ -z "$channel" ] || [ -z "$attrPath" ]; then
            # attrPath 同定に失敗したパッケージ (drvPath がどの候補スコープにも
            # 一致しなかった)。名前だけで推測しないので known/outdated は出さない。
            echo "nixos_package_upstream_attr_resolved{name=\"$name\"} 0"
            continue
          fi
          echo "nixos_package_upstream_attr_resolved{name=\"$name\"} 1"

          versionsFile="$work/versions-''${channel}.json"
          upstream_version=""
          if [ -f "$versionsFile" ]; then
            upstream_version=$(jq -r --arg k "$attrPath" '.[$k] // empty' "$versionsFile")
          fi

          if [ -n "$upstream_version" ]; then
            upstream_version=$(sanitize_label "$upstream_version")
            echo "nixos_package_upstream_known{name=\"$name\"} 1"
            echo "nixos_package_upstream_version_info{name=\"$name\",version=\"$upstream_version\"} 1"
            if [ "$upstream_version" = "$installed_version" ]; then
              echo "nixos_package_outdated{name=\"$name\"} 0"
            else
              echo "nixos_package_outdated{name=\"$name\"} 1"
            fi
          else
            # 属性は同定できたが、そのチャンネルの評価では見つからなかった
            # (rename / removal) か評価に失敗した。「更新なし」ではないので
            # outdated は出さない。
            echo "nixos_package_upstream_known{name=\"$name\"} 0"
          fi
        done < ${packageAttrsTsv}

        echo "nixos_package_upstream_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      staging=$(mktemp "${textfileDir}/.nixos-package-upstream-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };

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
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"

    # Repology 方式をやめた際 (2026-09-23) に出力ファイル名が変わった。
    # textfile collector はディレクトリ内の *.prom を無条件に読むため、
    # 旧ファイルを消さないと node_exporter が死んだ nixos_package_repology_*
    # を永久に配り続ける (実機で確認)。コレクタ側では消せない — 名前が
    # 変わった時点で旧ファイルはどのユニットの管理下でもなくなるため。
    "r ${textfileDir}/repology-package-status.prom - - - -"
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
  # nixpkgs 直接評価によるパッケージ更新チェック: チャンネルあたり nix 呼び出し
  # 2回 (metadata 解決 + バルク評価) で済む。旧 Repology 方式のような
  # 「パッケージ数 x 1秒」の律速が無いので、TimeoutStartSec は評価キャッシュが
  # 冷えている最悪ケース (nixpkgs tarball の取得) を見込んでも 10 分で十分。
  # 頻繁に動かす意味も薄い (upstream のリリース頻度はそんなに速くない) ので
  # 1日1回。
  ##############################################################################
  systemd.services.nixos-package-upstream-metrics = {
    description = "インストール済みパッケージの更新有無 (追従先 nixpkgs と直接比較) を node_exporter の textfile として出力する";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe upstreamCollector;
      TimeoutStartSec = "10min";
      StateDirectory = "nixos-package-upstream";
      Environment = [
        "HOME=/var/lib/nixos-package-upstream"
        "NIX_REMOTE=daemon"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      # AF_UNIX は nix デーモンのソケット、AF_INET/6 はチャンネルの取得。
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.nixos-package-upstream-metrics = {
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
  #   systemctl start nixos-package-metrics hydra-build-metrics nixos-package-upstream-metrics
  #   cat /var/lib/prometheus-node-exporter-text-files/nixos-packages.prom
  #   cat /var/lib/prometheus-node-exporter-text-files/hydra-build-status.prom
  #   cat /var/lib/prometheus-node-exporter-text-files/nixos-package-upstream-status.prom
  #   curl -s localhost:9100/metrics | grep -E '^(nixos_installed|nixos_package_upstream|nixos_channel|hydra_)'
  ##############################################################################
}
