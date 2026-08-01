{ config, lib, pkgs, ... }:

##############################################################################
# サービス間の資源優先度 (cgroup v2)。
#
# なぜ 1 ファイルにまとめるか:
#   CPUWeight は絶対値ではなく「同じ階層にいる兄弟同士の取り分の比」です。
#   ここに挙げたユニットはすべて system.slice 直下の兄弟なので、値は
#   互いを見比べて初めて意味を持ちます。各モジュールに散らすと
#   片方だけ書き換えて比率が崩れるため、表として一箇所に置いています。
#
# 前提:
#   - podman のコンテナは、oci-containers が作る systemd サービスの cgroup の
#     "下" には入りません。conmon が machine.slice 直下の libpod-<id>.scope に
#     移すため、podman-*.service に CPUWeight を書いてもコンテナ内のプロセス
#     (Minecraft の JVM) には効きません。実機で確認済み:
#       podman-ftb-evolution.service/cpu.weight        = 1000  (podman 本体だけ)
#       machine.slice/libpod-<id>.scope/cpu.weight     = 100   (JVM はこちら)
#     scope 名はコンテナ ID なので nix から名指しできません。したがって
#     コンテナには --cgroup-parent で専用スライスを与え、スライス側に
#     重みを付けます (下の systemd.slices)。
#     Nice= も podman クライアントにしか効かないので使いません。
#   - services.ollama は DynamicUser で動きますが、ユニット自身は
#     system.slice 直下なので同様に扱えます。
#   - tailscaled は「他のサービスへの到達経路」なので、Minecraft より上に
#     置いています (下のコメント参照)。優先度を考えるときはサービス単体の
#     重さではなく、それが落ちたときに何が道連れになるかで見ること。
#
# 効かないもの:
#   - IOWeight: ZFS は blk-cgroup を通らないため、このホストでは無効です。
#     ディスク I/O の優先度制御は諦めて、CPU とメモリだけで調整しています。
#   - ZFS ARC はカーネル側の確保でどの cgroup にも計上されません。
#     MemoryHigh の合計 + arcMaxBytes (16 GiB) が物理 RAM (46 GiB) を
#     超えないように、自分で足し算して決めること。
#
# 確認方法:
#   systemd-cgtop                        # 実際の取り分
#   systemctl show -p CPUWeight -p MemoryHigh podman-ftb-evolution
##############################################################################

let
  # ユニット名は syncoid モジュールが commands の名前から作ります
  # (`syncoid-rpool-root` のようにエスケープされる)。名前を直書きすると
  # replication.nix 側で対象を足したときに漏れるので、そこから引きます。
  # syncoid モジュール内の escapeUnitName と同じ規則 (英数字・_ . - 以外を "-" に)。
  # lib には公開されていないので、ここに写しています。
  escapeUnitName = name:
    lib.concatMapStrings (s: if lib.isList s then "-" else s)
      (builtins.split "[^a-zA-Z0-9_.\\-]+" name);

  syncoidUnits = lib.mapAttrs'
    (name: _: lib.nameValuePair "syncoid-${escapeUnitName name}" {
      serviceConfig.CPUWeight = 20;
    })
    config.services.syncoid.commands;
in
{
  systemd.services = syncoidUnits // {
    ##########################################################################
    # tailscaled — Minecraft より上。
    #
    # 理由は 2 つあります。
    #   1. これが落ちると Grafana も Ollama も届かなくなります (network.nix と
    #      monitoring.nix のとおり、どちらも tailscale0 限定で公開しています)。
    #      障害調査でホストへ入る経路そのものなので、飢えさせると
    #      「重いから直しに行きたいのに入れない」が起きます。
    #   2. tailscale は WireGuard の暗号化をカーネルではなく tailscaled の
    #      ユーザー空間で回します。tailnet 越しに量を流すとき (Ollama の応答、
    #      Grafana の描画) は実際に CPU を食うので、重みが効いてきます。
    #
    # 常時食うプロセスではないため、高い重みを与えても Minecraft の取り分は
    # ほぼ減りません。CPUWeight は「使おうとしたときの比」であって予約ではなく、
    # tailscaled が要求しない間は 100% が他へ回ります。
    # メモリは数十 MB のデーモンなので MemoryLow は保険の値です。
    ##########################################################################
    tailscaled.serviceConfig = {
      CPUWeight = 2000;
      MemoryLow = "256M";
    };

    # Minecraft (podman) はここではなく下の systemd.slices で設定します。
    # コンテナはこのユニットの cgroup の下にいないためです (先頭のコメント参照)。

    ##########################################################################
    # Ollama — 最劣後。
    #
    # 推論が GPU に載っているうちは CPU をほとんど使いませんが、VRAM 14 GiB に
    # 収まらないモデルを読ませると CPU オフロードで 8 スレッドを埋め尽くします
    # (Ryzen 3 3300X は 4C/8T しかありません)。そのとき Minecraft から CPU を
    # 奪わせないための重みです。空いていれば低い重みでも全部使えます。
    #
    # MemoryHigh はソフト上限 (超えると回収圧がかかるだけで kill されない)。
    # 巨大モデルを読んだときにページキャッシュごと他を押し出すのを抑えます。
    ##########################################################################
    ollama.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "14G";
    };

    # Open WebUI は RAG の埋め込み以外はほぼ待ち受けているだけ。
    open-webui.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "4G";
    };

    ##########################################################################
    # n8n — 待ち受けている間はほぼ無負荷ですが、ワークフローの実行時だけ
    # Node のプロセスが跳ねます。Minecraft から CPU を奪わせないよう
    # Ollama / Open WebUI と同じ最劣後に置いています。
    #
    # MemoryHigh はソフト上限。n8n 2.x は task runner を別プロセスで回すため、
    # ワークフロー次第でメモリが伸びます。ここで頭打ちにしておかないと
    # ZFS ARC (16 GiB) と Minecraft のヒープ (8 GiB) を圧迫します。
    ##########################################################################
    n8n.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "2G";
    };

    ##########################################################################
    # 監視 — 軽いが、障害時こそ動いていてほしいので極端には下げない。
    # cadvisor だけは全コンテナを走査して周期的に重くなるので落とします。
    #
    # 複製 (syncoid) は上の syncoidUnits で CPUWeight = 20 にしています。
    # 夜間の一括転送なので遅れても実害がありません。
    #
    # podman-mc-monitor はコンテナなのでここでは設定できません。
    # machine.slice 側 (下記) でまとめて下げています。
    ##########################################################################
    cadvisor.serviceConfig.CPUWeight = 20;
  };

  ############################################################################
  # スライス — podman コンテナ用。
  #
  # ここは system.slice の中ではなく cgroup ツリーの最上位の兄弟なので、
  # 上の CPUWeight とは別の階層で比較されます。まず root 直下で
  #   system.slice : minecraft.slice : machine.slice : user.slice
  # の比で分配され、その中を上の重みでさらに分けます。
  #
  # system.slice を既定の 100 から 1000 に引き上げているのは、Minecraft を
  # 1000 にした結果 tailscaled (system.slice の中で 2000) が root 段で
  # 頭打ちになるのを防ぐためです。両者を同格にして、飽和時は
  # 「Minecraft に半分、system.slice 側に半分 (その中は tailscaled 優先)」
  # という分かりやすい形にしています。
  ############################################################################
  systemd.slices = {
    # Minecraft コンテナ専用 (ftb-evolution.nix の --cgroup-parent と対)。
    # MemoryMax ではなく MemoryLow なのは前と同じ理由 — 上限を掛けると
    # JVM がヒープを確保できずに落ちます。
    minecraft = {
      description = "Minecraft server container slice";
      sliceConfig = {
        CPUWeight = 1000;
        MemoryLow = "10G";
      };
    };

    # 上記以外のコンテナ (podman-mc-monitor) の置き場。podman の既定の
    # 親スライスなので、明示的に指定していないコンテナはここに落ちます。
    machine.sliceConfig.CPUWeight = 20;

    # 上のコメントのとおり、root 段で minecraft.slice と同格にする。
    system.sliceConfig.CPUWeight = 1000;
  };
}
