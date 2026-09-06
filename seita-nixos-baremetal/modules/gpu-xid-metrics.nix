{ config, lib, pkgs, ... }:

##############################################################################
# NVIDIA の Xid エラー (カーネルログにしか出ない致命的な GPU 異常) を
# node_exporter の textfile として出し、Grafana アラートで拾えるようにする。
#
# 何のためか (2026-08-28 実機の障害):
#   GPU1 (0000:06:00.0) が "GPU has fallen off the bus" (Xid 79) で脱落し、
#   ドライバが両 GPU に "Node Reboot Required" (Xid 154) を立てた。
#   nvidia-smi は GPU1 を列挙できなくなり、ollama はモデルを CPU
#   フォールバックで動かし続け (nvidia-gpu-exporter のスクレイプ自体は
#   生き続けるため scrape-target-down は発報しない)、OpenViking の
#   summary/extract タスクが APITimeoutError で全滅した。気づいたのは
#   「昨夜から summary task が全部失敗している」とユーザーが言い出した
#   翌朝で、実際の発生からは数時間ズレていた。
#
#   modules/monitoring.nix の nvidia-gpu-exporter (nvidia_smi ベース) は
#   Xid を一切出さない (README.md の「NVIDIA は MIG / XID / ... が出ません」
#   の通り、utkuozdemir 版・mindprince 版どちらも Xid 非対応)。
#   Xid はカーネルログにしか出ないため、journalctl を読む以外に検知経路が無い。
#
# なぜ textfile collector か:
#   modules/zfs-snapshot-metrics.nix と同じ理由。専用 exporter が無く、
#   5 分間隔なら journalctl を読む負荷は無視できる。
#
# なぜ「今のブートで見えているか」で判定するか (差分カウンタにしない):
#   Xid 79 / 154 は「直った」と自動では分からない致命的な異常で、
#   ドライバ自身が要求する回復手段は再起動のみ。つまり実質的には
#   zfs_pool_health と同じ「状態」であり、cursor を持ち回して新規行だけ
#   数えるカウンタにする理由がない。`journalctl -k -b 0` を毎回読み直す
#   だけなら状態が壊れる (cursor ファイル破損、収集の取りこぼし) 心配も無い。
#   `-b 0` (今のブートに限定) なので、過去の障害を再起動後まで
#   延々と誤検知し続けることもない。
##############################################################################

let
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # 致命的 (再起動が必要、または GPU が実質使用不能になる) と判断できる Xid。
  #   79  = GPU has fallen off the bus (実機で確認)
  #   154 = GPU recovery action changed to Node Reboot Required (実機で確認)
  # 他の Xid (13 の Graphics Engine Exception 等) はゲームのシェーダバグ等
  # 良性の要因でも出るため、ここには含めない。誤検知よりも「これが出たら
  # 確実に再起動が要る」ものだけに絞る。
  fatalXids = [ "79" "154" ];

  collector = pkgs.writeShellApplication {
    name = "gpu-xid-metrics";
    runtimeInputs = [ pkgs.systemd pkgs.gawk pkgs.coreutils ];
    text = ''
      out="${textfileDir}/gpu-xid.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # 今のブートのカーネルログだけを対象にする (理由は上のコメント)。
      journalctl -k -b 0 -g 'NVRM: Xid' -o cat > "$work/xid-lines" || true

      gawk -v fatal="${lib.concatStringsSep " " fatalXids}" '
        BEGIN {
          split(fatal, arr, " ")
          for (i in arr) isFatal[arr[i]] = 1
        }
        # 例: "NVRM: Xid (PCI:0000:06:00): 79, pid=... GPU has fallen off the bus."
        match($0, /Xid \(PCI:([0-9a-fA-F:.]+)\): ([0-9]+)/, m) {
          pci = m[1]
          xid = m[2]
          seen[pci] = 1
          count[pci, xid]++
          if (xid in isFatal) rebootRequired[pci] = 1
        }
        END {
          print "# HELP gpu_xid_events_current_boot 今のブートで観測した Xid の件数"
          print "# TYPE gpu_xid_events_current_boot counter"
          for (key in count) {
            split(key, parts, SUBSEP)
            printf "gpu_xid_events_current_boot{pci=\"%s\",xid=\"%s\"} %d\n", parts[1], parts[2], count[key]
          }

          print "# HELP gpu_reboot_required 致命的な Xid (fallen off the bus 等) が今のブートで出ているなら 1"
          print "# TYPE gpu_reboot_required gauge"
          for (pci in seen) {
            bad = (pci in rebootRequired) ? 1 : 0
            printf "gpu_reboot_required{pci=\"%s\"} %d\n", pci, bad
          }
        }
      ' "$work/xid-lines" > "$work/out"

      {
        echo "# HELP gpu_xid_metrics_last_run_seconds この収集が最後に成功した時刻 (unix 秒)"
        echo "# TYPE gpu_xid_metrics_last_run_seconds gauge"
        echo "gpu_xid_metrics_last_run_seconds $(date +%s)"
      } >> "$work/out"

      # mv による原子的な置き換え (zfs-snapshot-metrics.nix と同じ理由)。
      staging=$(mktemp "${textfileDir}/.gpu-xid.XXXXXX")
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

  systemd.services.gpu-xid-metrics = {
    description = "NVIDIA Xid エラーを node_exporter の textfile として出力する";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;

      # journalctl -k は特権無しでも読めるが (SystemdJournalGatewayd 等の
      # ACL は使っていない)、確実性を優先してここも zfs-snapshot-metrics と
      # 同じ短命 root ユニットにしている。書き込み先だけを絞る。
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.gpu-xid-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 致命的な GPU 異常は「気づくまでの時間」がそのまま被害時間になるため、
      # ZFS 系 (5 分) より短くしている。journalctl -k -b 0 は今のブート分
      # だけなので 2 分間隔でも負荷は無視できる。
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      RandomizedDelaySec = "15s";
      Persistent = true;
    };
  };

  ############################################################################
  # 動作確認
  #
  #   systemctl start gpu-xid-metrics
  #   cat /var/lib/prometheus-node-exporter-text-files/gpu-xid.prom
  #   curl -s localhost:9100/metrics | grep -E '^gpu_(xid|reboot)'
  #
  #   疑似的に発報させたい場合 (実機の Xid を待たずに経路を確認する):
  #     一時的に modules/alerting.nix 側のルールを vector(1) にする方が安全
  #     (本物の Xid ログを流し込むテストは避ける)。
  ############################################################################
}
