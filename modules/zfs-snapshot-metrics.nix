{ config, lib, pkgs, ... }:

##############################################################################
# ZFS のスナップショットと syncoid 複製の状況を Grafana から見えるようにする。
#
# 何のためか:
#   スナップショットと複製は「静かに壊れる」種類の仕組みです。
#   autoSnapshot が止まっても、syncoid が実は何も送っていなくても、
#   普段の運用では何も起きません。気づくのは復旧しようとした瞬間で、
#   そのときにはもう手遅れです。定期的に zfs list を叩いて数値にしておけば、
#   dashboards/40-zfs-replication.json から一目で状態が分かります。
#
# なぜ textfile collector か:
#   専用の ZFS スナップショット exporter は定番と呼べるものが無く、
#   nixpkgs にも入っていません。node_exporter の zfs コレクタは ARC と
#   プール統計は出しますが、スナップショットの世代や作成時刻は出しません。
#   textfile collector なら常駐プロセスを増やさずに済み、出力は
#   ただのテキストファイルなので中身を目で確認できます。
#
#   実測で `zfs list -t snapshot` はスナップショット 285 個に対して 0.26 秒。
#   5 分間隔なら負荷は無視できます。
#
# 中心となる指標 = 複製遅延:
#   dpool/backup/X の最新スナップショット時刻と、複製元 rpool/X の
#   最新スナップショット時刻の差が、そのまま「今 SSD が死んだら
#   どれだけ失うか」です。syncoid ユニットの終了コードより信頼できます
#   — ユニットが成功で終わっていても、実際には何も転送していない
#   (送信側にスナップショットが無い等) 状態を捕まえられるためです。
#
#   syncoid ユニット自体の状態は node_exporter の systemd コレクタが既に
#   出しているので (node_systemd_unit_state{name="syncoid-rpool-*"})、
#   ここでは重複して収集しません。
##############################################################################

let
  # node_exporter の textfile collector が読むディレクトリ。
  # modules/monitoring.nix の extraFlags と対になっています。
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  collector = pkgs.writeShellApplication {
    name = "zfs-snapshot-metrics";
    runtimeInputs = [ config.boot.zfs.package pkgs.gawk pkgs.coreutils ];
    text = ''
      out="${textfileDir}/zfs-snapshots.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # 3 種類の情報を別々に取ってから 1 つの awk でまとめます。
      # zfs コマンドを 1 回にまとめる書き方もできますが、出力の形が
      # 違うものを 1 本のパイプで捌くと読めなくなるのでこうしています。
      #
      # -p は数値を秒/バイトの生値で出させるため (人間向けの "1.5G" では困る)。
      zfs list -H -o name                        > "$work/datasets"
      zfs get -Hp -o name,value usedbysnapshots  > "$work/usedby"
      zfs list -t snapshot -H -p -o name,creation > "$work/snapshots"

      gawk -F'\t' '
        FILENAME ~ /datasets$/  { seen[$1] = 1; next }
        FILENAME ~ /usedby$/    { usedby[$1] = $2; next }

        # スナップショット名は "データセット@ラベル"。@ の左側で束ねます。
        {
          at = index($1, "@")
          ds = substr($1, 1, at - 1)
          count[ds]++
          t = $2 + 0
          if (!(ds in newest) || t > newest[ds]) newest[ds] = t
          if (!(ds in oldest) || t < oldest[ds]) oldest[ds] = t
        }

        END {
          print "# HELP zfs_snapshot_count データセットが持つスナップショットの数"
          print "# TYPE zfs_snapshot_count gauge"
          print "# HELP zfs_snapshot_latest_creation_seconds 最新スナップショットの作成時刻 (unix 秒)"
          print "# TYPE zfs_snapshot_latest_creation_seconds gauge"
          print "# HELP zfs_snapshot_oldest_creation_seconds 最古スナップショットの作成時刻 (unix 秒)"
          print "# TYPE zfs_snapshot_oldest_creation_seconds gauge"
          print "# HELP zfs_dataset_usedbysnapshots_bytes スナップショットだけが参照している容量"
          print "# TYPE zfs_dataset_usedbysnapshots_bytes gauge"

          for (ds in seen) {
            # スナップショットが 1 つも無いデータセットも 0 で出します。
            # 出さないと「取れていない」と「取るのをやめた」の区別が
            # ダッシュボード上で付きません (系列が消えるだけになる)。
            n = (ds in count) ? count[ds] : 0
            printf "zfs_snapshot_count{dataset=\"%s\"} %d\n", ds, n

            if (ds in newest) {
              printf "zfs_snapshot_latest_creation_seconds{dataset=\"%s\"} %d\n", ds, newest[ds]
              printf "zfs_snapshot_oldest_creation_seconds{dataset=\"%s\"} %d\n", ds, oldest[ds]
            }

            if (ds in usedby) {
              printf "zfs_dataset_usedbysnapshots_bytes{dataset=\"%s\"} %d\n", ds, usedby[ds]
            }
          }
        }
      ' "$work/datasets" "$work/usedby" "$work/snapshots" > "$work/out"

      # 収集自体の死活。この値が古くなっていたら、以下の数字はすべて
      # 信用できません (タイマーが止まっている / zfs コマンドが失敗している)。
      {
        echo "# HELP zfs_snapshot_metrics_last_run_seconds この収集が最後に成功した時刻 (unix 秒)"
        echo "# TYPE zfs_snapshot_metrics_last_run_seconds gauge"
        echo "zfs_snapshot_metrics_last_run_seconds $(date +%s)"
      } >> "$work/out"

      # node_exporter が書きかけのファイルを読まないよう、同一ファイルシステム上で
      # 作ってから mv します (mv が rename(2) になるので原子的)。
      # mktemp -d が /tmp を指すと別ファイルシステムになるため、
      # ここで一度 textfileDir 側へ移してから rename しています。
      staging=$(mktemp "${textfileDir}/.zfs-snapshots.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  # node_exporter は User=node-exporter で ProtectSystem=strict のため、
  # 読むだけならこの権限で足ります。書くのは下の root のユニットだけです。
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];

  systemd.services.zfs-snapshot-metrics = {
    description = "ZFS スナップショット状況を node_exporter の textfile として出力する";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;

      # zfs list は読み取りだけですが /dev/zfs を開く必要があり、
      # 非 root では権限委譲 (zfs allow) が要ります。データセットが増えるたびに
      # 委譲を足すのは運用が破綻しやすいので、読み取り専用の短命ユニットとして
      # root で動かし、代わりに書き込み先を絞る方針にしています。
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.zfs-snapshot-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # autoSnapshot の最短間隔が 15 分なので、5 分あれば十分追随できます。
      # これより短くしても新しい情報は増えません。
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      # 起動直後に他のサービスと重ならないよう少しずらす。
      RandomizedDelaySec = "30s";
      Persistent = true;
    };
  };

  ############################################################################
  # 動作確認
  #
  #   systemctl start zfs-snapshot-metrics
  #   cat /var/lib/prometheus-node-exporter-text-files/zfs-snapshots.prom
  #   curl -s localhost:9100/metrics | grep '^zfs_snapshot'
  #
  #   textfile collector が転んでいないか (0 なら正常):
  #     curl -s localhost:9100/metrics | grep node_textfile_scrape_error
  ############################################################################
}
