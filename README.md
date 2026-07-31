# NixOS on ZFS — SSD×1 + HDD×2 (mirror) 構成 / disko 管理

参考: <https://wiki.nixos.org/wiki/ZFS> / <https://github.com/nix-community/disko>

ディスクレイアウトは [disko](https://github.com/nix-community/disko) で宣言的に管理します。
パーティショニング・zpool 作成・データセット作成・`fileSystems` の生成はすべて
[disko/default.nix](disko/default.nix) 1枚から行われます。

---

## 0. クイックスタート（SSH 自動インストール）

NixOS installer ISO で起動し、SSH で root として接続している前提。**3台のディスクは完全に消去されます。**

```bash
# ISO 側で SSH を有効にする (未設定なら)
#   passwd            # root パスワードを設定
#   systemctl start sshd

# 作業マシンから設定一式を転送
scp -r nixos-zfs root@<installer-ip>:/root/

# ISO 側で
cd /root/nixos-zfs
ls -l /dev/disk/by-id/ | grep -v part     # ディスク ID を確認
vi scripts/disks.env                      # ★ここだけ書き換える★
bash scripts/install.sh
```

[scripts/install.sh](scripts/install.sh) がやること:

1. **事前チェック** — root / UEFI 起動 / 必要コマンド / ZFS モジュール / ディスク実在・重複・容量差 / `cache.nixos.org` 疎通
2. **tmux 自動再入** — SSH セッションなら `tmux new-session -A -s nixos-install` で自分を exec し直す（切断してもインストールが死なない）
3. `disks.env` → [machine.nix](machine.nix) を生成（hostId は ISO の `/etc/machine-id` から、**SSH 公開鍵は ISO の `/root/.ssh/authorized_keys` から自動で引き継ぎ**）
4. `nixos-generate-config --no-filesystems --show-hardware-config` でハードウェア検出
5. **ドライラン評価** — ディスクを触る前に Nix 側の評価エラーを落とす
6. `disko --mode destroy,format,mount`
7. `nixos-install` → 設定一式を `/mnt/etc/nixos` へ配置

主なオプション:

| オプション | 動作 |
|---|---|
| `--yes` | 確認プロンプトなし（完全無人） |
| `--config-only` | `machine.nix` 生成とドライラン評価まで。**ディスクは触らない** |
| `--format-only` | disko でフォーマット・マウントまで。`nixos-install` はしない |
| `--skip-format` | disko を実行せず、マウント済みの `/mnt` にインストールだけ行う |
| `--no-tmux` | tmux への自動再入をしない |

ログは `/tmp/nixos-zfs-install.log`。切断したら `tmux attach -t nixos-install` で復帰します。

> **[configuration.nix](configuration.nix) は `PasswordAuthentication = false` です。** 公開鍵もパスワードハッシュも無いまま
> 進めると再起動後に SSH で入れなくなります。`install.sh` は ISO の authorized_keys を自動で引き継ぎ、
> どちらも無い場合は警告して確認を求めます。パスワードを使うなら `mkpasswd -m yescrypt` の出力を
> `disks.env` の `USER_PASSWORD_HASH` に入れてください。

---

## 1. 構成の全体像

```
SSD (NVMe/SATA, 1台)
 ├─ part1  1 GiB    EF00  EFI System Partition  → /boot
 ├─ part2  32 GiB   8200  swap (randomEncryption)
 ├─ part3  8 GiB          slog    … 予約のみ (useSlog = true で dpool の log vdev に)
 └─ part4  残り全部 BF00  rpool   … システム用 ZFS プール (single vdev)

HDD ×2 (同容量)
 └─ dpool : mirror(hdd1, hdd2)   … データ用 ZFS プール
```

| マウントポイント | データセット | 置き場所 |
|---|---|---|
| `/` | `rpool/root` | SSD |
| `/var` `/var/log` `/var/lib` | `rpool/var*` | SSD |
| `/tmp` | `rpool/tmp` (`sync=disabled`) | SSD |
| `/home` | `dpool/home` | HDD mirror |
| `/srv` | `dpool/srv` | HDD mirror |
| `/srv/minecraft` | `rpool/srv/minecraft` | SSD（下記参照） |
| `/nix` | `dpool/nix` または `rpool/nix` | `nixPool` 次第 |
| `/boot` | vfat パーティション | SSD |

- **`/srv/minecraft` だけ SSD 側です。** HDD (`ST4000DM004`) が SMR で、Minecraft の
  オートセーブが `write(2)` で 60 秒以上ブロックし、サーバーが自分の watchdog に
  落とされていたためです（[8 章の障害事例](#障害事例-minecraft-が-60-秒の-tick-で再起動を繰り返す)参照）。
  rpool は冗長性が無いので、`modules/replication.nix` の syncoid が
  `dpool/backup/minecraft` へ日次で複製しています。

- **読み込みキャッシュは ARC（RAM）だけです**。SSD を使う二次キャッシュ（L2ARC / cache vdev）は
  **使いません**。以前は part5 を dpool の cache に充てていましたが、実運用で起動不能障害の
  引き金になったため廃止しました（[8 章の障害事例](#障害事例-nvme-脱落による起動不能)参照）。
  読み込み性能が足りなければ、cache を足すのではなく `arcMaxBytes`（= RAM）を増やします。
- **SLOG**: 同期書き込み (NFS サーバ、DB) にしか効きません。デスクトップ用途ではほぼ無意味なので**既定では予約のみ**です。

### やってはいけないこと（重要）

**`special` vdev（メタデータ専用 vdev）を SSD 1台で dpool に足さないでください。**
`cache`/`log` と違い `special` はプールの一部です。SSD が死ぬと **HDD ミラーごと全損**します。
やるなら SSD 2台でミラーにしてください。[disko/default.nix](disko/default.nix) でも意図的に使っていません。

### `/nix` を HDD に置くことについて

`machine.nix` の `nixPool`（= `disks.env` の `NIX_POOL`）で切り替えます。

読み込みは ARC（RAM 上のキャッシュ）が吸収するため、一度触ったファイルは実質 
RAM 速度になります。HDD 速度のまま残るのは:

- **書き込み全般** — ビルド成果物の展開、`nix copy`、substitute の展開
- **`nix-collect-garbage`** — 大量の unlink = メタデータ書き込み
- **再起動直後の初回読み込み** — ARC は揮発性なので毎回温め直しになります

体感で `nixos-rebuild switch` が SSD 比 2〜4 倍、GC は数倍〜十倍、日常操作はほぼ差なし、というあたりです。

それでも **`nixPool = "dpool"`（HDD）を推奨します**。nix store はビルドと GC で大量に
書き込むため、SSD に置くと寿命を顕著に削ります。廉価な SSD では特に重要です。

**切り替えはインストール時に決めてください。** 後から移すには `zfs send | zfs recv` が必要です。

---

## 2. ファイル構成

| ファイル | 役割 | 誰が書くか |
|---|---|---|
| [flake.nix](flake.nix) | エントリポイント。`nixpkgs` + `disko` を input に持つ | 固定 |
| [machine.nix](machine.nix) | **マシン固有値**（hostId, 3台の by-id, サイズ, nixPool, ユーザー, SSH 鍵…） | `install.sh` が生成 |
| [disko/default.nix](disko/default.nix) | ディスク・プール・データセットの宣言 | 固定（`machine.nix` を参照） |
| [hardware-configuration.nix](hardware-configuration.nix) | CPU / カーネルモジュール等の検出結果 | `nixos-generate-config` が生成 |
| [configuration.nix](configuration.nix) | ブートローダー、ユーザー、SSH、Nix 設定 | 固定（`machine.nix` を参照） |
| [modules/zfs.nix](modules/zfs.nix) | ZFS 本体・ARC・NVMe 対策・autoScrub/trim/snapshot・smartd | 固定 |
| [modules/unstable.nix](modules/unstable.nix) | 選んだツールだけ unstable から引くオーバーレイ | 適宜編集 |
| [scripts/bench-pools.sh](scripts/bench-pools.sh) | rpool / dpool の性能測定 | 必要時に実行 |
| [scripts/disks.env](scripts/disks.env) | **ユーザーが書き換える唯一のファイル** | ユーザー |
| [scripts/install.sh](scripts/install.sh) | 上記を束ねるインストーラ | 固定 |

マシン固有の値は `machine.nix` 1ファイルに集約してあるので、**他の nix ファイルは基本的に触りません**。

---

## 3. 事前準備

### 3.1 ISO で起動

ZFS 入りの NixOS minimal ISO で起動します（公式 minimal ISO で OK）。

```bash
sudo -i
```

### 3.2 ディスクの by-id パスを確認

**必ず `/dev/disk/by-id/` を使ってください。** `/dev/sda` などのバス依存名でプールを作ると、
接続順が変わった時にインポートに失敗します。

```bash
ls -l /dev/disk/by-id/ | grep -v part
```

### 3.3 セクタサイズの確認（ashift 決定用）

```bash
lsblk -o NAME,PHY-SEC,LOG-SEC,ROTA,MODEL
```

物理セクタ 4096 (=4Kn/512e) なら `ashift=12`。最近の 8TB 以上の HDD には
物理 16 KiB (`ashift=14`) のものもあります。**ashift はプール作成後に変更できません。**
迷ったら `12` で問題ありません。

---

## 4. disko レイアウトの読み方

[disko/default.nix](disko/default.nix) で押さえておくべき点。

### 4.1 topology と「予約パーティション」

disko の `_create` は、**`pool = "..."` を宣言したパーティションがすべて topology に登場しているか**を
検証し、一致しないと `not all disks accounted for` でプール作成をスキップします。

そのため SLOG を使わない場合、part3 は `content` を付けない**ただの予約領域**にしてあります:

```nix
slog = {
  priority = 3;
  size = m.slogSize;
  content = lib.mkIf m.useSlog { type = "zfs"; pool = "dpool"; };
};
```

`useSlog = true` にすると content が付き、同時に topology の `log` にも追加されます。

### 4.2 member のフルパス指定

topology の `members` は、`/` で始まらない場合
`/dev/disk/by-partlabel/disk-<disk名>-zfs` に解決されます。
SSD には zfs パーティションが複数あるため、SLOG は**フルパスで指定**しています:

```nix
log = [ { members = [ "/dev/disk/by-partlabel/disk-ssd-slog" ]; } ];
```

HDD 側は例外的に `members = [ "hdd1" "hdd2" ]` と名前で書けます（各ディスクの zfs パーティション名が
`zfs` なので上の規則で解決されるため）。

### 4.3 mountpoint=legacy

全データセットに `options.mountpoint = "legacy"` を設定し、実際のマウントは disko が生成する
`fileSystems` に一本化しています。`zfsutil` 方式より、`zfs-mount.service` と systemd の
mount unit が競合するトラブルを避けやすいためです。

### 4.4 `/nix` のプロパティ

NixOS wiki の指示どおり、`/nix` のデータセットには非 POSIX 系プロパティ
(`normalization`, `utf8only`, `atime=off`, `snapdir=visible`, `acltype=nfsv4`) を設定していません。
`atime=off` ではなく `relatime=on` を使い、ストアは再現可能なのでスナップショット対象外にしています。

---

## 5. 手動で実行する場合

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"

# machine.nix を自分の値に書き換えてから
vi machine.nix

# ハードウェア検出 (--no-filesystems: fileSystems/swapDevices は disko が持つので生成させない)
nixos-generate-config --no-filesystems --show-hardware-config > hardware-configuration.nix

# ディスクを触る前に評価チェック
nix eval --raw .#nixosConfigurations."$(hostname)".config.system.build.toplevel.drvPath

# パーティショニング〜マウント
nix run github:nix-community/disko/latest -- --mode destroy,format,mount --flake .#"$(grep -oP 'hostName = "\K[^"]+' machine.nix)"

# 確認
zpool status && zpool list -v && findmnt -R /mnt

# インストール
nixos-install --root /mnt --flake .#"$(grep -oP 'hostName = "\K[^"]+' machine.nix)"

# 再起動
umount -R /mnt && swapoff -a && zpool export -a && reboot
```

disko の `--mode` は用途で使い分けます:

| mode | 動作 |
|---|---|
| `destroy` | 既存のプール・パーティションを破棄 |
| `format` | パーティショニングとプール・データセット作成 |
| `mount` | `/mnt` 以下にマウント |
| `destroy,format,mount` | 上記すべて（新規インストール時） |
| `mount` のみ | レスキュー時に既存プールを `/mnt` に再マウント |

---

## 6. 起動後の確認

```bash
zpool status -v
zpool list -v
zfs list -o name,used,avail,compressratio,mountpoint
arc_summary | head -40
```

ディスクの健全性もこの段階で見ておきます。特に NVMe の **Percentage Used**（寿命消費率）は
定期的に確認してください。コンシューマ向け SSD はこれが 80% を超えるごろから
書き込みレイテンシが不安定になりやすくなります:

```bash
sudo smartctl -a /dev/nvme0 | grep -iE "percentage used|temperature|critical|media errors|unsafe"
sudo nvme smart-log /dev/nvme0
```

---

## 7. 運用

### スクラブ

`services.zfs.autoScrub.enable = true;` で毎月自動実行されます。手動:

```bash
zpool scrub dpool
zpool status dpool
```

### スナップショット

`services.zfs.autoSnapshot` で frequent/hourly/daily/weekly/monthly を自動取得します。
`/tmp`, `/var/log`, `/nix` は対象外にしてあります。

```bash
zfs list -t snapshot -o name,used,refer -s creation | tail -20
```

復元:

```bash
# 単一ファイル
cp /home/user/.zfs/snapshot/zfs-auto-snap_daily-2026-07-26-0000/foo.txt ~/
# データセット全体
zfs rollback dpool/home@zfs-auto-snap_daily-2026-07-26-0000
```

### HDD 故障時の交換

```bash
zpool status dpool                       # DEGRADED のデバイスを確認
zpool offline dpool /dev/disk/by-id/ata-OLD
# 物理交換後
zpool replace dpool /dev/disk/by-id/ata-OLD /dev/disk/by-partlabel/disk-hdd1-zfs
zpool status dpool                       # resilver の進捗
```

交換後は `machine.nix` の `hdd1` / `hdd2` を新しい by-id に更新しておいてください
（次回 disko を流すときのため）。

### SSD 故障時

- **rpool は失われます**（single vdev）。`/home` と `/srv` は dpool に残るので無事です。
- dpool の `cache` は自動的に切り離されるだけでデータは無傷です。
- SSD 交換後は `machine.nix` の `ssd` を更新し、**同じ flake で再インストール**すれば復帰します。
  dpool は消したくないので `--mode destroy,format,mount` は使わず、rpool だけ作り直してください。
- **`/etc/nixos` は git で別管理してください。** rpool の中身は flake から作り直せるのが原則です。

**唯一の例外が `/srv/minecraft`（Minecraft のワールド）です。** flake からは再生成できず、
かつ SMR HDD の I/O 問題で rpool に置かざるを得ませんでした。これを守るために
`modules/replication.nix` の syncoid が `dpool/backup/minecraft` へ日次複製しています。
rpool を作り直したあとは、受信側から戻します:

```bash
zfs list -t snapshot -r dpool/backup/minecraft          # 最新の世代を確認
zfs send dpool/backup/minecraft@<最新> | zfs recv -u rpool/srv/minecraft

# recv は親 (rpool) のプロパティを継承するので、必ず設定し直すこと。
# com.sun:auto-snapshot を忘れると以後スナップショットも複製も止まります。
zfs set mountpoint=legacy rpool/srv/minecraft
zfs set com.sun:auto-snapshot=true rpool/srv/minecraft
zfs set atime=off rpool/srv/minecraft
```

失われるのは最後の複製以降（最大 1 日ぶん）です。もっと短くしたい場合は
`services.syncoid.commands."rpool/srv/minecraft".interval` を個別に設定してください
（`services.syncoid.interval` を変えると `rpool/root` と `rpool/var/lib` も巻き添えになります）。

### バックアップ

ZFS ミラーはバックアップではありません（誤削除・ランサムウェア・筐体ごとの障害には無力）。
`zfs send -R` で外付け or リモートへ定期送信してください。

```bash
zfs snapshot -r dpool@backup-$(date +%F)
zfs send -R -I dpool@backup-PREV dpool@backup-$(date +%F) | ssh backup zfs recv -Fu tank/dpool
```

### 日常のリビルド

```bash
sudo nixos-rebuild switch --flake /etc/nixos
```

---

## 8. トラブルシューティング

### 起動時に `pool was previously in use from another system` で止まる

```
cannot import 'dpool': pool was previously in use from another system.
Last accessed by nixos (hostid=8425e349)
The pool can be imported, use 'zpool import -f' to import the pool.
...
An error occurred in stage 1 of the boot process
```

**原因**: ZFS はプール作成時に「作ったホストの hostid」をラベルに刻みます。
これが実行中システムの hostid と一致していれば、非クリーンな停止後でも import は通ります。
逆に食い違っていると、クラッシュや電源断が一度でも起きた時点で ZFS が
「他システムで使用中」と判断して拒否します。

古い `install.sh` は ISO の hostid のまま disko を走らせていたため、この不一致が
必ず発生していました（実際にこれで起動不能になりました）。現在は disko 実行前に
ISO の `/etc/hostid` を最終的な `hostId` に揃えるので、この失敗経路は消えています。

**復旧**: installer ISO で起動して、インポートし直してからクリーンにエクスポートします。

```bash
sudo zpool import -f rpool
sudo zpool import -f dpool
sudo zpool export rpool
sudo zpool export dpool
sudo reboot
```

再インストールは不要です。

**予防**: 次の3つで三重に守っています。

1. `scripts/install.sh` が **disko を走らせる前に** ISO の `/etc/hostid` を
   `machine.nix` に入る `hostId` と同じ値に揃える（根本的な防御）
2. `scripts/install.sh` が最後に `umount -R /mnt && swapoff -a && zpool export -a` を自動実行する
3. `modules/zfs.nix` の `boot.zfs.forceImportRoot = true`（NixOS 既定値）

`forceImportRoot` を `false` にしてはいけません。`false` が意味を持つのは SAN や共有ストレージのように
他ホストが同じプールを現に使っている可能性がある構成だけで、ローカルディスク専用機では
**hostid 不一致のたびに起動不能になるだけ**です。

### 障害事例: NVMe 脱落による起動不能

上の `pool was previously in use from another system` は、**クリーンにシャットダウンできなかった
結果**としても出ます。実運用で踏んだ事例を記録します。

**症状**: Minecraft サーバを動かした程度の負荷でマシンが応答しなくなり、強制再起動後に
stage 1 で起動不能になる。

**連鎖の全体像**:

```
nvme nvme0: I/O tag 37 timeout, aborting req_op:WRITE
nvme nvme0: Admin Cmd QID 0 timeout, reset controller
  ↓
INFO: task l2arc_feed:223 blocked for more than 245 seconds.
INFO: task zfs:14576 blocked for more than 245 seconds.
  ↓
systemd-journald.service: Watchdog timeout (limit 3min)!
podman-minecraft.service: Stopping timed out.
NetworkManager.service: State 'stop-sigterm' timed out. Killing.
  ↓
シャットダウンが完走できず強制リセット → プールが未 export
  ↓
次回起動時に initrd の import が失敗
```

**真因**: rpool のある NVMe が I/O タイムアウトでコントローラリセットされたこと。
メモリ不足でも熱でもありませんでした（RAM 46 GiB に対し ARC 実使用 1 GiB、SSD 45℃）。
搭載していたのが DRAM レスの廉価 NVMe（ADATA LEGEND 700）で、SMART の
**Percentage Used が 78%** まで進んでいました。

**悪化要因**として、このリポジトリ自体の旧構成が寄与していました。
1 本の NVMe に **rpool + swap + L2ARC** を集約し、さらに `l2arc_write_max` /
`l2arc_write_boost` を既定の 4〜8 倍に引き上げていたためです。
L2ARC への書き込みは純粋な摩耗であり、ARC に余裕がある構成では見返りがほぼありません。
（実測: ARC 上限 16 GiB に対し実使用 1 GiB。L2ARC の出番はまったく無かった）

**対策**（いずれも適用済み）:

1. **L2ARC の完全廃止** — [disko/default.nix](disko/default.nix) から cache vdev を削除し、
   [modules/zfs.nix](modules/zfs.nix) の l2arc_* チューニングも撤去。**復活させないこと**。
   稼働中のマシンでは無損失・即時に外せます:
   ```bash
   sudo zpool remove dpool <zpool status の cache 行に出ているデバイス名>
   ```
2. **NVMe カーネルパラメータ** — [modules/zfs.nix](modules/zfs.nix) に追加済み:
   - `nvme_core.default_ps_max_latency_us=0`（APST 無効化。低電力ステートからの復帰失敗を回避）
   - `nvme_core.io_timeout=255`（既定 30 秒。SLC キャッシュ枯渇時の数十秒の遅延を
     コントローラ故障と誤認させない）
3. **SMART 監視の実効化** — `services.smartd` の属性監視を有効化し、`nvme-cli` を導入。

**確認方法**: 同じ負荷をかけながら監視し、`timeout` / `reset controller` が出なければ解決です。

```bash
sudo journalctl -f -k | grep -i nvme
```

それでも再現する場合はドライブ自体の限界なので、**交換が唯一の対策**です。
rpool は single vdev で冗長性がないため、この SSD が死ぬとシステムは飛びます
（`/home` と `/srv` は HDD ミラーの dpool に残ります）。

### 障害事例: Minecraft が 60 秒の tick で再起動を繰り返す

**症状**: プレイヤーから見ると「接続がタイムアウトする」。実際にはサーバーが落ちて
`Restart=always` で上がり直しています。1 日に 7 回起きていました。

```
[Server Watchdog/ERROR] A single server tick took 60.00 seconds (should be max 0.05)
[Server Watchdog/ERROR] Considering it to be crashed, server will forcibly shutdown.
systemd[1]: podman-ftb-evolution.service: Main process exited, code=exited, status=1/FAILURE
```

これは systemd や podman のタイムアウトではなく、**Minecraft 自身の ServerHangWatchdog**
です（`TimeoutStartSec=infinity` なので systemd 側は無関係）。

**切り分け**: クラッシュレポートのスレッドダンプで `"Server thread"` がどこにいるかを見ます。

```bash
journalctl -u podman-ftb-evolution --since "2 days ago" | grep -a -A30 '"Server thread" prio'
```

```
"Server thread" RUNNABLE
  at sun.nio.ch.UnixFileDispatcherImpl.write0(Native Method)   ← 生の write(2) で止まっている
  at net.minecraft.nbt.NbtIo.writeCompressed
  at MinecraftServer.saveAllChunks / saveEverything / tickServer
```

`write0` にいれば mod ではなく **I/O 待ち**で確定です。mod が原因なら、そこに
mod のクラス名が出ます。

**原因**: dpool の HDD (`ST4000DM004`) が **SMR** でした。持続的なランダム上書きで
内部の CMR キャッシュが溢れると応答が数十秒級になり、ZFS の書き込みスロットル
(`zfs_dirty_data_max`) が `write(2)` を止めます。裏付けになった数字:

```bash
cat /proc/pressure/io     # full avg300=43% — マシン全体が I/O で 4 割止まっていた
zpool status -x           # all pools are healthy — ディスク故障ではない
```

同じ 1.5 GB のバックアップ所要時間が 68 秒 → 92 秒 → 109 秒 → **239 秒** と単調に
劣化していたのが決定的でした。SMR キャッシュ枯渇の典型です。

**対策**: ワールドを rpool（NVMe）へ移し、`modules/replication.nix` の syncoid で
dpool へ日次複製する構成にしました。**`modules/resource-priority.nix` では直せません** —
ZFS は blk-cgroup を通らないため `IOWeight` が効かず、CPU とメモリの重みは
I/O 競合に対して無力だからです。

同時に modpack 同梱の FTB Backups 3 を無効化しています（1.5 GB の zip を 2 時間ごとに
同じプールへ書いており、ZFS スナップショットと役割が完全に重複していました）。

**SSD 寿命への影響**: 990 PRO 1TB の TBW は 600 TB。ワールドの書き込みは
アイドル時 4 MB/時（hourly スナップショットの差分で実測）、ホスト全体でも 13 GiB/日 で、
100 年単位の計算になります。寿命を理由にためらう必要はありません。

### クラッシュ後に原因を調べる

次の 2 つをまず見ます。前回ブートのログに何が出ているかで、切り分けがほぼ決まります。

```bash
free -h                                          # メモリ不足か
grep -E "^(size|c_max) " /proc/spl/kstat/zfs/arcstats   # ARC 上限と実使用量
sudo journalctl --list-boots | tail -5
sudo journalctl -b -1 -p warning --no-pager | tail -60
```

| ログに出るもの | 原因 |
|---|---|
| `Out of memory: Killed process` | メモリ不足。`arcMaxBytes` を下げる |
| `nvme ... timeout, reset controller` | 上の NVMe 脱落事例 |
| `INFO: task ... blocked for more than N seconds` | I/O スタック。直前の行に真因がある |
| `Machine Check Exception` | CPU / メモリのハード障害。memtest86+ へ |
| `thermal` / `Critical temperature` | 放熱不足 |
| 何も残っていない | 電源断や熱による即死。ハード側を痑う |

**hostid の確認方法**（import 拒否の切り分けに使います）:

```bash
hostid                              # 実行中システム
sudo zdb -C dpool | grep -i hostid  # プール側 (10 進数で出る)
cat /etc/hostid | xxd               # initrd に焼かれる値 (リトルエンディアン)
```

3 つが一致していれば、非クリーンな停止後でも import は通ります。
なお `sudo` なしの `zdb` は Permission denied の後に ASSERT と backtrace を吐きますが、
これは後始末の既知の不具合であってプール破損ではありません。

### `NAR hash mismatch in input 'path:...'`

```
error: NAR hash mismatch in input 'path:/home/nixos/nixos-zfs?lastModified=...',
expected 'sha256-...' but got 'sha256-...'
```

**原因**: `--flake` に渡したディレクトリの中身が、評価中に変化しています。
`nix` はディレクトリ全体を NAR ハッシュ化して入力として扱うため、
flake ツリーの中にログファイルなどを書き続けると発生します。

**対処**: flake ディレクトリ内に生成物を置かないこと。

```bash
rm -f ~/nixos-zfs/install.log
```

`install.sh` はログを `/tmp`（書けなければ `$HOME` 直下）に出すようにしてあり、
flake ツリーの中には決して書きません。

### `not all disks accounted for, skipping creating zpool`

disko が出すメッセージです。`pool = "..."` を宣言したパーティションのうち、
topology に登場していないものがあります。[4.1 節](#41-topology-と予約パーティション)を参照してください。

### プールが `DEGRADED` になった

```bash
zpool status -v            # どのデバイスが落ちたか
smartctl -a /dev/sdX       # 物理的な健全性
```

HDD 側なら [7 章の交換手順](#hdd-故障時の交換)へ。
SSD 側（rpool）は single vdev なので DEGRADED にはならず、壊れればそのまま全損です。
