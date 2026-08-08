{ config, lib, pkgs, ... }:

##############################################################################
# Tailscale Serve による HTTP サービスの集約 (reverse proxy)。
#
# 何のために入れるか:
#   Grafana (3000) / Open WebUI (8080) / Ollama (11434) / n8n (5678) を
#   tailnet 上の 1 つの HTTPS 入口にまとめ、ポート番号を覚えずに済ませます。
#
# なぜ nginx ではなく Tailscale Serve か:
#   このリポジトリにはまだ秘密情報の置き場 (sops-nix / agenix) がありません。
#   nginx で TLS を張るには証明書が要り、ACME は
#     - HTTP-01 なら 80/tcp を WAN に開ける (tailnet 限定という方針が崩れる)
#     - DNS-01 なら API トークンを置く (秘密情報が 2 つ目になる)
#   のどちらかを強います。Tailscale Serve は tailscaled が MagicDNS 名に対する
#   Let's Encrypt 証明書を自前で取得・更新するため、秘密情報を 1 つも
#   持ち込まずに TLS 終端できます。常駐ユニットも増えません。
#
# 対象外:
#   - Minecraft (25565) は HTTP ではないので対象外です。
#   - VictoriaMetrics (8428) と exporter 群は 127.0.0.1 のまま前に出しません。
#     VictoriaMetrics は無認証で /api/v1/admin/tsdb/delete_series を受け付けます。
##############################################################################

let
  m = import ../machine.nix;

  # tailnet の MagicDNS サフィックス。
  # 確認方法:
  #   tailscale status --json | grep MagicDNSSuffix
  # tailnet を作り直すとここが変わり、証明書の名前も変わります。
  tailnetSuffix = "tail5426c0.ts.net";

  fqdn = "${m.hostName}.${tailnetSuffix}";
  baseUrl = "https://${fqdn}";

  # n8n だけ別ポート (理由は下の routes のコメント)
  n8nUrl = "https://${fqdn}:8443";

  # ComfyUI も別ポート (理由は下の routes のコメント)
  comfyuiUrl = "https://${fqdn}:9443";

  ############################################################################
  # 振り分け表
  #
  # path = null がルート (/) へのマウント。httpsPort が待ち受け側のポートです。
  #
  # ★ 大前提: Tailscale Serve は --set-path の prefix を「剥がして」から
  #   バックエンドへ渡します ★
  #   つまり /grafana にマウントしたサービスに届くのは /login であって
  #   /grafana/login ではありません。サブパスに置くアプリ側には
  #   「自分はルートで待ち受けるが、生成する URL にだけ prefix を付ける」
  #   設定が要ります。この非対称が下の追随設定の理由です。
  #
  # ★ Open WebUI が 443 のルートを占有しているのは趣味ではなく制約です ★
  #   open-webui 0.6.9 の FastAPI 生成箇所 (open_webui/main.py) には root_path
  #   引数が無く、Python ソース全体で root_path が 1 件も出てきません。
  #   サブパス配下に置くと静的アセットと API 呼び出しが / を向いて壊れます。
  #   回避策は無いため、Open WebUI は必ずルートに置いてください。
  #
  # ★ n8n だけ別ポート (8443) のルートに分けています ★
  #   n8n をサブパスに置くには N8N_PATH が要りますが、これはフロントエンドの
  #   ベースパス (window.BASE_PATH) を書き換えるだけで、バックエンドの
  #   待ち受けはルートのまま動きません。結果、prefix を剥がすプロキシ経由では
  #   正常に動く一方、**LAN からの直接アクセスが壊れます** —
  #   HTML が指す /n8n/assets/*.js にバックエンドがキャッチオールの HTML を
  #   返すためで、ブラウザは白画面になります (実機で確認済み)。
  #   n8n は LAN にも開いたままにする方針なので、prefix を使わずに済む
  #   別ポートへ逃がし、N8N_PATH を設定しない形にしています。これで
  #   http://<LAN IP>:5678/ と https://<fqdn>:8443/ の両方が素直に動きます。
  #
  # ★ Ollama を /ollama にマウントしてはいけません ★
  #   Open WebUI が 443 のルートを占有しており、**Open WebUI 自身が
  #   /ollama/* を Ollama へのプロキシとして使っています** (認証付き)。
  #   ここに Serve のマウントを足すと、より長い prefix が優先されて
  #   Open WebUI の /ollama/* が丸ごと横取りされます。症状は管理画面の
  #   Settings > Connections が読み込み中のまま止まることで、devtools には
  #     GET https://<fqdn>/ollama/config 404 (Not Found)
  #   が出ます (Ollama 本体には /config が無いため)。実機で確認:
  #   127.0.0.1:8080/ollama/config は 401 = 存在する、
  #   127.0.0.1:11434/config は 404。2026-08-04 に遭遇して外しました。
  #
  #   外しても到達性は失われません。ollama CLI や OLLAMA_HOST を使う
  #   クライアントはベース URL にパスを含められず、そもそも /ollama/ では
  #   繋がらないため、Ollama の口は tailscale0 の 11434 直結
  #   (modules/ollama.nix) が唯一の経路です。
  #
  # ★ ComfyUI も n8n と同じく別ポート (9443) のルートにしています ★
  #   ComfyUI のフロントエンドはサブパス/ベースパスでのリバースプロキシ配下
  #   運用に正式対応していません (絶対パスで API を呼ぶ箇所があり、prefix を
  #   剥がすプロキシ経由だと壊れます)。443 のルートは Open WebUI が占有して
  #   おり、8443 は n8n が使っているため、新しいポートに逃がしています。
  ############################################################################
  routes = [
    { path = null;       httpsPort = 443;  port = 8080;  note = "open-webui"; }
    { path = "/grafana"; httpsPort = 443;  port = 3000;  note = "grafana"; }
    { path = null;       httpsPort = 8443; port = 5678;  note = "n8n"; }
    { path = null;       httpsPort = 9443; port = 8188;  note = "comfyui"; }
  ];

  # Serve が使う HTTPS ポート (ファイアウォールで開ける対象)
  httpsPorts = lib.unique (map (r: r.httpsPort) routes);

  tailscaleBin = "${config.services.tailscale.package}/bin/tailscale";

  serveCommand = r:
    let
      setPath = lib.optionalString (r.path != null) "--set-path=${r.path} ";
    in
    "${tailscaleBin} serve --bg --yes --https=${toString r.httpsPort} ${setPath}${toString r.port}  # ${r.note}";
in
{
  ############################################################################
  # Serve の設定を宣言的に適用する
  #
  # tailscale serve の設定は本来 /var/lib/tailscale の state に書き込まれる
  # 「その場の状態」で、git にも nix store にも残りません。それでは
  # このリポジトリの方針 (構成の正は git) から外れるため、適用そのものを
  # systemd ユニットにして上の routes を唯一の正にしています。
  #
  # 先頭で serve reset しているのがその要です。差分適用ではなく毎回
  # 白紙から作り直すので、routes から行を消せば実機からも消えます。
  # (reset 無しだと、消したはずのマウントが state に残り続けます)
  #
  # RemainAfterExit = true にしてあるので、nixos-rebuild switch でユニットの
  # 内容が変わったときに再実行され、変更が反映されます。
  #
  # ★ 逆に言うと「ユニットの内容が変わらない変更」は反映されません ★
  #   下の serveCommand が埋め込むのは --set-path とポート番号だけで、fqdn は
  #   ここに現れません (Grafana の root_url とコメントにしか使っていない)。
  #   そのため m.hostName や tailnetSuffix を変えても ExecStart の文字列は
  #   1 文字も変わらず、switch は再起動対象と判定しません。実機の serve は
  #   /var/lib/tailscale の state に残った旧 FQDN のまま動き続けます。
  #   ホスト名か tailnet を変えたら手で明示的に:
  #     sudo systemctl restart tailscale-serve
  #   (2026-08-01 の seita-nix-baremetal → seita-nixos-baremetal 改名で遭遇)
  ############################################################################
  systemd.services.tailscale-serve = {
    description = "Apply declarative Tailscale Serve configuration";

    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # tailscaled がまだ認証されていない (sudo tailscale up 前) 状態では
      # 失敗します。それは黙って諦めるより見えた方がよいのでリトライします。
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # tailscaled が上がって tailnet に参加するまで待つ。
      # after=tailscaled.service だけでは「プロセスが起動した」ところまでしか
      # 保証されず、バックエンドが Running になる前に serve を叩くと失敗します。
      for _ in $(seq 1 60); do
        if ${tailscaleBin} status --json | grep -q '"BackendState": *"Running"'; then
          break
        fi
        sleep 2
      done

      # 毎回作り直す (上のコメント参照)
      ${tailscaleBin} serve reset

      ${lib.concatMapStringsSep "\n" serveCommand routes}
    '';
  };

  ############################################################################
  # ファイアウォール
  #
  # Serve への到達は tailscale0 の 443 と 8443 です (routes から導出)。
  # tailscale0 は信頼インタフェースにしていない (他モジュールがポートを
  # 個別に開けている) ので、ここで明示的に開ける必要があります。
  #
  # なお各サービスの直接ポート (3000 / 8080 / 11434) は他モジュールで
  # tailscale0 に開いたままにしてあります。Serve 経由に移行しきったら
  # modules/monitoring.nix の
  # firewall.interfaces."tailscale0".allowedTCPPorts から外せます。
  # ただし Ollama の 11434 は外せません — Serve に Ollama のマウントは
  # 無く (上の routes のコメント参照)、ここが唯一の到達経路です。
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = httpsPorts;

  ############################################################################
  # 各サービス側の追随設定
  #
  # 前段にプロキシを置くと、アプリが自分で生成する絶対 URL とリダイレクト先が
  # 内部のポート番号を向いたままになり壊れます。その補正をここに集めています。
  # (各サービスのモジュールに散らすと、この module を外したときに戻し忘れます)
  ############################################################################

  # --- Grafana ---------------------------------------------------------------
  # root_url が絶対 URL なので、monitoring.nix の domain はもう使われません
  # (あちらは触っていないので、この module を外せば元の挙動に戻ります)。
  #
  # ★ serve_from_sub_path は false でなければなりません ★
  #   Tailscale Serve は --set-path のマウント時に prefix を *剥がして* から
  #   バックエンドへ渡します。つまり Grafana に届くのは /login であって
  #   /grafana/login ではありません。ここで serve_from_sub_path = true にすると
  #   Grafana は「サブパスが付いていない」と判断して /grafana/login へ 301 を返し、
  #   その要求もまた剥がされて /login で届くため、無限リダイレクトになります
  #   (実機で確認済み: curl -L が --max-redirs で打ち切られる)。
  #   false なら Grafana は / で待ち受けたまま、生成する URL にだけ root_url の
  #   サブパスを付けるので、prefix を剥がすプロキシと正しく噛み合います。
  services.grafana.settings.server = {
    root_url = "${baseUrl}/grafana/";
    serve_from_sub_path = false;
  };

  # --- n8n -------------------------------------------------------------------
  # ★ N8N_PATH は設定しません ★
  #   n8n は 8443 のルートにマウントしてあり prefix が無いので不要です。
  #   むしろ設定してはいけません — N8N_PATH はフロントエンドの
  #   window.BASE_PATH を書き換えるだけでバックエンドの待ち受けは動かさず、
  #   LAN からの直接アクセス (http://<LAN IP>:5678/) を白画面にします。
  #   詳しくは上の routes のコメントを参照。
  #
  # N8N_PROXY_HOPS は前段のプロキシの段数です。これを設定しないと n8n は
  # TCP のピア (= tailscaled、つまり自分自身) をクライアント IP と見なし、
  # レート制限と監査ログのアドレスが無意味になります。
  #
  # WEBHOOK_URL を設定しないと、UI が表示する webhook の URL が
  # http://<内部IP>:5678/... のままになり、外部サービスに登録しても届きません。
  # これだけは環境変数を直書きせず専用オプションを使います — NixOS の n8n
  # モジュールが WEBHOOK_URL = "" を無条件に定義しており、environment 側に
  # 書くと定義が衝突して eval が落ちるためです。
  #
  # N8N_SECURE_COOKIE = "false" は n8n.nix 側でそのままにしてあります。
  # LAN の平文 HTTP の口を残す判断をしているため、ここを立てると
  # そちらからログインできなくなります。
  services.n8n.webhookUrl = "${n8nUrl}/";

  systemd.services.n8n.environment = {
    N8N_PROXY_HOPS = "1";
    N8N_EDITOR_BASE_URL = "${n8nUrl}/";
  };

  # --- Open WebUI ------------------------------------------------------------
  # 共有リンクやメール中の URL の生成に使われます。
  # (待ち受けは / のままなので、ここは表示上の URL だけの問題です)
  services.open-webui.environment = {
    WEBUI_URL = baseUrl;
  };

  ############################################################################
  # 運用メモ
  #
  #   適用結果の確認:
  #     systemctl status tailscale-serve
  #     tailscale serve status
  #
  #   証明書 (tailscaled が自動で取得・更新します):
  #     tailscale cert ${fqdn}
  #
  #   アクセス先:
  #     ${baseUrl}/          Open WebUI
  #     ${baseUrl}/grafana/  Grafana
  #     ${n8nUrl}/           n8n  (LAN からは http://<LAN IP>:5678/ も従来どおり)
  #     ${comfyuiUrl}/       ComfyUI
  #     Ollama API は Serve を通しません: http://<tailscale IP>:11434/
  #
  #   全部剥がして元に戻す:
  #     flake.nix の modules から ./modules/reverse-proxy.nix を外して rebuild し、
  #     sudo tailscale serve reset
  ############################################################################
}
