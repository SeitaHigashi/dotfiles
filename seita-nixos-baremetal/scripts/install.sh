#!/usr/bin/env bash
#
# NixOS on ZFS 一括インストーラ (disko 版)
#   SSD x1 (EFI + swap + slog予約 + rpool) + HDD x2 mirror (dpool)
#
# 想定: NixOS の installer ISO で起動し、SSH で root として接続している状態。
#
#   !!! 指定した3台のディスクの内容は完全に消去されます !!!
#
# 使い方:
#   1. scripts/disks.env を自分の環境に書き換える
#   2. bash scripts/install.sh
#
# パーティショニング・プール作成・データセット作成・マウントはすべて
# disko/default.nix の宣言から disko が行います。このスクリプトの仕事は
#   disks.env -> machine.nix の生成、事前チェック、disko と nixos-install の起動
# だけです。
#
# オプション:
#   --yes              確認プロンプトを出さない (完全無人)
#   --no-tmux          tmux への自動再入をしない
#   --config-only      machine.nix の生成とドライラン評価まで。ディスクは触らない
#   --format-only      disko でフォーマット・マウントまで。nixos-install はしない
#   --skip-format      disko を実行しない (既に /mnt がマウント済みの前提で再開)
#   --remount          既存プールを破棄せず /mnt にマウントし直してから nixos-install。
#                      インストールをやり直したいがデータは残したい場合に使う
#   --no-export        最後に /mnt の umount と zpool export を行わない
#                      (通常は指定しないこと。export し忘れは起動不能の原因になる)
#   --list-disks       このマシンのディスクと by-id パスを一覧表示して終了
#   --bench            プール作成直後に性能のベースラインを測り /root に保存する
#                      (数分かかります。--bench-size で測定サイズを変更可)
#   --bench-size <N>   ベンチのテストサイズ (既定 4G)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# FLAKE は disks.env を読み込んだ後に決めます (構成名 = ホスト名のため)。
FLAKE=""
LOG=/tmp/nixos-zfs-install.log

ASSUME_YES=0
NO_TMUX=0
CONFIG_ONLY=0
FORMAT_ONLY=0
SKIP_FORMAT=0
LIST_DISKS=0
NO_EXPORT=0
REMOUNT=0
BENCH=0
BENCH_SIZE=4G

# --bench-size だけ値を取るので、前の引数を覚えながら回す。
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--bench-size" ]]; then BENCH_SIZE="$arg"; prev=""; continue; fi
  case "$arg" in
    --yes|-y)      ASSUME_YES=1 ;;
    --no-tmux)     NO_TMUX=1 ;;
    --config-only) CONFIG_ONLY=1 ;;
    --format-only) FORMAT_ONLY=1 ;;
    --skip-format) SKIP_FORMAT=1 ;;
    --remount)     REMOUNT=1 ;;
    --no-export)   NO_EXPORT=1 ;;
    --list-disks)  LIST_DISKS=1; NO_TMUX=1 ;;
    --bench)       BENCH=1 ;;
    --bench-size)  prev="--bench-size" ;;
    -h|--help)     sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "不明なオプション: $arg" >&2; exit 1 ;;
  esac
done

##############################################################################
# SSH 切断で install が死なないように tmux の中で動かす
##############################################################################
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" \
      && "${NIXOS_ZFS_IN_TMUX:-0}" != "1" && "$NO_TMUX" != "1" ]]; then
  if command -v tmux >/dev/null 2>&1; then
    echo "SSH セッションを検出しました。tmux 'nixos-install' 内で実行します。"
    echo "切断した場合は再接続後に:  tmux attach -t nixos-install"
    sleep 2
    export NIXOS_ZFS_IN_TMUX=1
    exec tmux new-session -A -s nixos-install -- "${BASH_SOURCE[0]}" "$@"
  else
    echo "警告: SSH 接続かつ tmux/screen の外で実行しています。"
    echo "      切断するとインストールが中断されます。"
    echo "      nix-shell -p tmux で入れてから実行し直すことを推奨します。"
    if [[ "$ASSUME_YES" != "1" ]]; then
      read -r -p "このまま続行しますか? [y/N]: " a
      [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
    fi
  fi
fi

# ログ先を決める。
#   ★ $REPO_DIR (flake のソースツリー) の中には絶対に置かないこと ★
#   nix eval / nixos-install は --flake に渡したディレクトリを丸ごと NAR ハッシュ化して
#   入力として扱うため、実行中にそこへ追記し続けるとディレクトリ内容が変わり続け、
#   最初に評価した時点のハッシュと後で読み込んだ時点のハッシュが食い違って
#   "NAR hash mismatch" で失敗する (実際に踏んだ不具合)。
# /tmp が書けない環境 (権限・read-only 等) では $HOME 直下 (repo の外) に落とし、
# それも駄目ならログ無しで続行する。ログはあくまで補助なので、ここで止めない。
if ! ( : >> "$LOG" ) 2>/dev/null; then
  LOG="${HOME:-/root}/nixos-zfs-install.log"
  ( : >> "$LOG" ) 2>/dev/null || LOG=""
fi
if [[ -n "$LOG" ]]; then
  exec > >(tee -a "$LOG") 2>&1
  echo "===== $(date -Is) install.sh (disko) 開始 (log: $LOG) ====="
else
  echo "===== $(date -Is) install.sh (disko) 開始 (ログファイルは書けないので画面のみ) ====="
fi

# installer ISO では flakes が既定で無効なので、この実行中だけ有効化する
export NIX_CONFIG="experimental-features = nix-command flakes"

# shellcheck source=disks.env
source "$SCRIPT_DIR/disks.env"

# flake の構成名はホスト名と同じです (flake.nix が machine.nix の hostName を使う)。
# こうしておくと、インストール後は属性名を省いて
#   sudo nixos-rebuild switch --flake /etc/nixos
# と書けます。
#
# 注意: HOSTNAME は bash 自身が実行中マシンのホスト名で設定する変数です。
# disks.env に HOSTNAME= の行が無いと、ISO のホスト名 ("nixos") が黙って
# 使われて構成名が食い違います。空チェックでは検出できないので、
# disks.env に定義があること自体を確認します。
grep -qE '^[[:space:]]*HOSTNAME=' "$SCRIPT_DIR/disks.env" \
  || { echo "ERROR: disks.env に HOSTNAME= の行がありません。" >&2; exit 1; }
[[ -n "${HOSTNAME:-}" ]] \
  || { echo "ERROR: HOSTNAME が空です。" >&2; exit 1; }
FLAKE="${REPO_DIR}#${HOSTNAME}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==================== $* ===================="; }

# ディスク指定が間違っているときに、そのまま貼れる候補一覧を出す
list_disks() {
  echo
  echo "--- このマシンのディスク ---"
  lsblk -dno NAME,SIZE,ROTA,MODEL | while read -r name size rota model; do
    if [[ "$rota" == "1" ]]; then kind="HDD"; else kind="SSD/NVMe"; fi
    printf '  /dev/%-10s %-8s %-9s %s\n' "$name" "$size" "$kind" "$model"
  done
  echo
  echo "--- disks.env に貼る by-id パス (パーティションを除く) ---"
  for l in /dev/disk/by-id/*; do
    [[ -L "$l" ]] || continue
    case "$l" in *-part*) continue ;; esac
    tgt="$(readlink -f "$l")"
    [[ -b "$tgt" ]] || continue
    # /dev/sda 等の実体を持つものだけ、サイズ付きで出す
    printf '  %-12s %s\n' "$(lsblk -dno SIZE "$tgt" 2>/dev/null)" "$l"
  done | sort -u
  echo
  echo "  (wwn-... より nvme-Model_Serial / ata-Model_Serial 形式の方が読みやすいです)"
}

if [[ "$LIST_DISKS" == "1" ]]; then
  list_disks
  exit 0
fi

##############################################################################
# 事前チェック
##############################################################################
step "事前チェック"

[[ "$(id -u)" -eq 0 ]] || die "root で実行してください (sudo -i)。"
[[ -d /sys/firmware/efi ]] || die "UEFI で起動していません。この構成は systemd-boot (UEFI) 前提です。"

missing=()
for c in nix nixos-generate-config nixos-install zpool zfs; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[[ ${#missing[@]} -eq 0 ]] || die "コマンドが見つかりません: ${missing[*]}"

modprobe zfs 2>/dev/null || true
zpool version >/dev/null 2>&1 || die "ZFS カーネルモジュールが使えません。ZFS 入りの ISO で起動してください。"

bad=0
for v in SSD HDD1 HDD2; do
  d="${!v}"
  if [[ "$d" == *XXXXXXX* || "$d" == *YYYYYYY* ]]; then
    echo "ERROR: $v が disks.env のテンプレートのままです: $d" >&2
    bad=1
  elif [[ ! -b "$d" ]]; then
    echo "ERROR: $v のブロックデバイスがありません: $d" >&2
    bad=1
  fi
done
if [[ "$bad" == "1" ]]; then
  list_disks
  die "$SCRIPT_DIR/disks.env の SSD / HDD1 / HDD2 を上の by-id パスに書き換えてください。"
fi
[[ "$(readlink -f "$SSD")"  != "$(readlink -f "$HDD1")" ]] || die "SSD と HDD1 が同一デバイスです。"
[[ "$(readlink -f "$SSD")"  != "$(readlink -f "$HDD2")" ]] || die "SSD と HDD2 が同一デバイスです。"
[[ "$(readlink -f "$HDD1")" != "$(readlink -f "$HDD2")" ]] || die "HDD1 と HDD2 が同一デバイスです。"

case "$NIX_POOL" in rpool|dpool) ;; *) die "NIX_POOL は rpool か dpool にしてください (今: $NIX_POOL)" ;; esac
case "${USE_SLOG:-0}" in 0|1) ;; *) die "USE_SLOG は 0 か 1 にしてください (今: $USE_SLOG)" ;; esac

sz1=$(blockdev --getsize64 "$HDD1"); sz2=$(blockdev --getsize64 "$HDD2")
if [[ "$sz1" != "$sz2" ]]; then
  echo "警告: HDD の容量が異なります ($((sz1/1000/1000/1000))GB / $((sz2/1000/1000/1000))GB)。"
  echo "      mirror は小さい方の容量になります。"
fi

# disko と nixpkgs の取得、nixos-install のバイナリキャッシュに必要
curl -fsS -m 15 -o /dev/null https://cache.nixos.org/nix-cache-info \
  || die "cache.nixos.org に到達できません。ネットワーク設定を確認してください。"

##############################################################################
# machine.nix の生成
##############################################################################
step "マシン固有値の決定"

if [[ -z "${HOST_ID:-}" ]]; then
  HOST_ID="$(head -c 8 /etc/machine-id)"
  echo "hostId を /etc/machine-id から生成: $HOST_ID"
else
  echo "hostId (disks.env 指定): $HOST_ID"
fi
[[ "$HOST_ID" =~ ^[0-9a-fA-F]{8}$ ]] || die "hostId が 8 桁の 16 進数ではありません: $HOST_ID"

##############################################################################
# ★ ISO 側の hostid を、インストール後システムと同じ値に揃える ★
#
# ZFS はプール作成時に「作ったホストの hostid」をラベルに刻みます。
# 何もしないと ISO の hostid が刻まれ、インストール後システムの
# networking.hostId とは必ず食い違います。すると、非クリーンな停止
# (クラッシュ・電源断・kernel panic) が一度でも起きた時点で、次回起動時に
#   cannot import 'dpool': pool was previously in use from another system
# で stage 1 が止まり、起動不能になります。
#
# ここで先に ISO の /etc/hostid を揃えておけば、プールには最初から
# 最終的な hostid が刻まれ、この失敗経路そのものが消えます。
# (export 忘れ対策の boot.zfs.forceImportRoot = true とは別の、より根本的な防御)
#
# hostid の値そのものは何でも構いません (ISO ごとに変わって問題ありません)。
# 重要なのは「プールに刻まれる値」と「インストール後システムの networking.hostId」が
# 一致することだけです。ここで ISO 側を machine.nix と同じ値に揃えることで、
# 両者が必ず一致します。
#
# /etc/hostid は 4 バイトのリトルエンディアン。"5a8a0885" -> 85 08 8a 5a。
#
# ISO では /etc/hostid が /etc/static/... 経由で nix store へのシンボリックリンクに
# なっていることがあり、そのままリダイレクトすると store (read-only) に書きに行って
# 失敗します。先にリンクを消してから実体を作ります。
##############################################################################
h="${HOST_ID,,}"
rm -f /etc/hostid
printf "\\x${h:6:2}\\x${h:4:2}\\x${h:2:2}\\x${h:0:2}" > /etc/hostid \
  || die "/etc/hostid の書き込みに失敗しました (/etc が書き込み可能か確認してください)。"
actual_hostid="$(hostid)"
[[ "$actual_hostid" == "$h" ]] \
  || die "hostid の設定に失敗しました (期待: $h / 実際: $actual_hostid)。"
echo "ISO の hostid を $h に設定しました (プールにこの値が刻まれます)"
unset h actual_hostid

# SSH 公開鍵: disks.env 優先、無ければ ISO 上の authorized_keys を引き継ぐ。
# configuration.nix は PasswordAuthentication = false なので、
# これを取り違えると再起動後に締め出される。
keys_raw="${SSH_AUTHORIZED_KEYS:-}"
if [[ -z "$keys_raw" ]]; then
  for f in /root/.ssh/authorized_keys "$HOME/.ssh/authorized_keys"; do
    [[ -r "$f" ]] && keys_raw+="$(cat "$f")"$'\n'
  done
fi
mapfile -t SSH_KEYS < <(printf '%s\n' "$keys_raw" | sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' | sort -u)

# パスワードハッシュの形検査。
# disks.env をダブルクォートで書くと bash が $y$... を変数展開して壊すので、
# 「crypt 形式に見えない」場合はここで止める。
for v in USER_PASSWORD_HASH ROOT_PASSWORD_HASH; do
  h="${!v:-}"
  [[ -z "$h" ]] && continue
  if [[ ! "$h" =~ ^\$[0-9a-zA-Z]+\$ ]]; then
    die "$v が crypt 形式のハッシュに見えません: '$h'
       disks.env ではシングルクォートで囲んでください (ダブルクォートだと \$ が展開されて壊れます)。
         OK : $v='\$y\$j9T\$...'
         NG : $v=\"\$y\$j9T\$...\"
       生成:  nix-shell -p mkpasswd --run 'mkpasswd -m yescrypt'"
  fi
  # 平文パスワードの誤設定も弾く (crypt 形式でないものは上で落ちるが念のため)
  echo "$v: 形式 OK (${h:0:6}...)"
done

echo "引き継ぐ SSH 公開鍵: ${#SSH_KEYS[@]} 本"
for k in "${SSH_KEYS[@]}"; do echo "  ${k%% *} ... ${k##* }"; done

# ログイン手段が1つも無い状態を防ぐ。
#   1) SSH 公開鍵
#   2) machine.nix に埋めるパスワードハッシュ (Nix ストアに残る点に注意)
#   3) nixos-install が最後に対話で聞く root パスワード (/etc/shadow に直接書かれる)
if [[ "${PROMPT_ROOT_PASSWORD:-1}" == "1" ]]; then
  echo "root パスワード: nixos-install の最後に対話で設定します (/etc/shadow に直接書かれ、Nix ストアには残りません)"
  if [[ -z "${USER_PASSWORD_HASH:-}" ]]; then
    echo "  → ${USER_NAME} のパスワードは未設定です。初回起動後にコンソールで root ログインし、"
    echo "     passwd ${USER_NAME}  を実行してください。"
  fi
elif [[ ${#SSH_KEYS[@]} -eq 0 && -z "${USER_PASSWORD_HASH:-}" && -z "${ROOT_PASSWORD_HASH:-}" ]]; then
  echo
  echo "警告: ログイン手段が1つもありません。"
  echo "      PROMPT_ROOT_PASSWORD=0 かつ SSH 公開鍵もパスワードハッシュも未設定です。"
  echo "      再起動後にログインできなくなります。"
  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "それでも続行しますか? [y/N]: " a
    [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
  fi
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
  echo "注意: SSH 公開鍵が 0 本なので、再起動後は SSH で入れません (コンソールのみ)。"
  echo "      後から /etc/nixos/machine.nix の userSshKeys に足して"
  echo "      nixos-rebuild switch すれば有効になります。"
fi

step "machine.nix を生成"
nix_str() { # null か "文字列" を出力 (Nix 文字列としてエスケープ)
  if [[ -z "$1" ]]; then
    printf 'null'
  else
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$\{/\\\$\{}"
    printf '"%s"' "$s"
  fi
}
nix_bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }

{
  echo '# scripts/install.sh が scripts/disks.env から自動生成しました。'
  echo "# 生成日時: $(date -Is)"
  echo '{'
  printf '  hostName = "%s";\n'        "$HOSTNAME"
  printf '  hostId = "%s";\n'          "$HOST_ID"
  echo
  printf '  ssd  = "%s";\n'            "$SSD"
  printf '  hdd1 = "%s";\n'            "$HDD1"
  printf '  hdd2 = "%s";\n'            "$HDD2"
  echo
  printf '  efiSize   = "%s";\n'       "$EFI_SIZE"
  printf '  swapSize  = "%s";\n'       "$SWAP_SIZE"
  printf '  slogSize  = "%s";\n'       "$SLOG_SIZE"
  printf '  useSlog = %s;\n'           "$(nix_bool "${USE_SLOG:-0}")"
  printf '  ashift = "%s";\n'          "$ASHIFT"
  echo
  printf '  nixPool = "%s";\n'         "$NIX_POOL"
  printf '  arcMaxBytes = %s;\n'       "$ARC_MAX_BYTES"
  echo
  printf '  userName = "%s";\n'        "$USER_NAME"
  printf '  userDescription = "%s";\n' "$USER_DESCRIPTION"
  echo   '  userSshKeys = ['
  for k in "${SSH_KEYS[@]}"; do printf '    "%s"\n' "$k"; done
  echo   '  ];'
  printf '  userHashedPassword = %s;\n' "$(nix_str "${USER_PASSWORD_HASH:-}")"
  printf '  rootHashedPassword = %s;\n' "$(nix_str "${ROOT_PASSWORD_HASH:-}")"
  printf '  allowPasswordAuth = %s;\n'  "$(nix_bool "${ALLOW_PASSWORD_AUTH:-0}")"
  echo
  printf '  staticAddress = %s;\n'      "$(nix_str "${STATIC_ADDRESS:-}")"
  printf '  gateway = %s;\n'            "$(nix_str "${GATEWAY:-}")"
  echo   '  nameservers = ['
  for n in ${NAMESERVERS:-}; do printf '    "%s"\n' "$n"; done
  echo   '  ];'
  printf '  networkInterface = "%s";\n' "${NETWORK_INTERFACE:-en*}"
  echo '}'
} > "$REPO_DIR/machine.nix"

echo "--- $REPO_DIR/machine.nix ---"
sed -e 's/\(ssh-[a-z0-9]*\) \([A-Za-z0-9+/]\{16\}\)[A-Za-z0-9+/=]*/\1 \2.../' "$REPO_DIR/machine.nix"
echo "-----------------------------"

##############################################################################
# ハードウェア構成の検出
#   --no-filesystems: fileSystems / swapDevices を生成させない。
#   それらは disko が生成するので、あるとぶつかる。
##############################################################################
step "ハードウェア構成を検出"
nixos-generate-config --no-filesystems --show-hardware-config > "$REPO_DIR/hardware-configuration.nix"
echo "--- hardware-configuration.nix ---"
cat "$REPO_DIR/hardware-configuration.nix"
echo "----------------------------------"

##############################################################################
# ドライラン評価 (ディスクを触る前に構文・評価エラーを潰す)
##############################################################################
step "設定を評価 (ドライラン)"
# ディスクを触る前に、Nix 側の構文エラー・評価エラーをここで落とす。
nix eval --raw \
  "${REPO_DIR}#nixosConfigurations.\"${HOSTNAME}\".config.system.build.toplevel.drvPath" >/dev/null \
  || die "システム構成の評価に失敗しました。上のエラーを確認してください。"
echo "OK — システム構成"

nix eval --raw \
  "${REPO_DIR}#nixosConfigurations.\"${HOSTNAME}\".config.system.build.diskoScript" >/dev/null \
  || die "disko のレイアウト評価に失敗しました。disko/default.nix を確認してください。"
echo "OK — disko レイアウト"

##############################################################################
# 最終確認
##############################################################################
step "実行内容の確認"
cat <<EOF
  ホスト名     : $HOSTNAME  (hostId: $HOST_ID)
  ユーザー     : $USER_NAME
  /nix の場所  : $NIX_POOL  $( [[ "$NIX_POOL" == dpool ]] && echo "(HDD — SSD の書き込みを節約。ビルド/GC は HDD 速度)" || echo "(SSD)" )
  ARC 上限     : $((ARC_MAX_BYTES/1024/1024/1024)) GiB
  SLOG         : $( [[ "${USE_SLOG:-0}" == 1 ]] && echo "有効" || echo "無効 (part3 は予約のみ)" )

  消去されるディスク:
    SSD  $SSD
         -> $(readlink -f "$SSD")   $(lsblk -dno SIZE,MODEL "$(readlink -f "$SSD")")
    HDD1 $HDD1
         -> $(readlink -f "$HDD1")  $(lsblk -dno SIZE,MODEL "$(readlink -f "$HDD1")")
    HDD2 $HDD2
         -> $(readlink -f "$HDD2")  $(lsblk -dno SIZE,MODEL "$(readlink -f "$HDD2")")

  SSD: EFI ${EFI_SIZE} / swap ${SWAP_SIZE} / slog ${SLOG_SIZE} / 残り全部 rpool
  HDD: mirror (100% を1パーティション)
EOF

if [[ "$CONFIG_ONLY" == "1" ]]; then
  step "--config-only 指定のためここで終了 (ディスクは変更していません)"
  echo "続行する場合:"
  echo "  nix run github:nix-community/disko/latest -- --mode destroy,format,mount --flake ${FLAKE}"
  echo "  nixos-install --root /mnt --flake ${FLAKE}"
  exit 0
fi

# ディスクを消すのは destroy,format,mount のときだけ。
# --skip-format / --remount では既存プールを維持するので確認を出さない。
if [[ "$ASSUME_YES" != "1" && "$SKIP_FORMAT" != "1" && "$REMOUNT" != "1" ]]; then
  echo
  read -r -p "上記3台のディスクを消去して続行します。'YES' と入力: " ans
  [[ "$ans" == "YES" ]] || { echo "中止しました。"; exit 1; }
elif [[ "$REMOUNT" == "1" ]]; then
  echo
  echo "--remount 指定: 既存のプールとデータは破棄しません (マウントし直すだけ)。"
fi

##############################################################################
# disko: destroy -> format -> mount
##############################################################################
if [[ "$REMOUNT" == "1" ]]; then
  # 既存プールを破棄せず、/mnt にマウントし直すだけ。
  # nixos-install をやり直したいが、プールとデータはそのまま使いたい場合に使う。
  step "disko でマウントし直し (--remount / 既存プールは破棄しない)"
  mountpoint -q /mnt && { umount -R /mnt || die "/mnt のアンマウントに失敗しました。"; }

  nix run github:nix-community/disko/latest -- \
    --mode mount \
    --flake "$FLAKE"

elif [[ "$SKIP_FORMAT" != "1" ]]; then
  step "disko でパーティショニング・プール作成・マウント"

  # 既存プールが残っていると disko が「既にあるので作らない」と判断してしまうため、
  # destroy モードに入る前に手動で片付けておく。
  mountpoint -q /mnt && umount -R /mnt || true
  swapoff -a || true
  for p in rpool dpool; do
    if zpool list "$p" >/dev/null 2>&1; then
      echo "既存プール '$p' を破棄します。"
      zpool destroy -f "$p" || zpool export -f "$p" || true
    fi
  done
  # ZFS のラベルはディスク末尾にもあるので消しておく
  for d in "$SSD"* "$HDD1"* "$HDD2"*; do
    [[ -b "$d" ]] && zpool labelclear -f "$d" >/dev/null 2>&1 || true
  done

  nix run github:nix-community/disko/latest -- \
    --mode destroy,format,mount \
    --flake "$FLAKE"
else
  step "disko をスキップ (--skip-format)"
  mountpoint -q /mnt || die "/mnt がマウントされていません。
       既にプールは作成済みで、マウントし直してから再開したい場合は --remount を使ってください:
         sudo bash $0 --remount"
fi

step "マウント結果"
zpool status
echo
zpool list -v
echo
findmnt -R /mnt

##############################################################################
# プール性能のベースライン測定 (--bench 指定時のみ)
#
# プールが出来た直後、まだ何も載っていないこの時点が最も条件が揃います
# (断片化なし・スナップショットなし・他の I/O なし)。ここで取った値が
# 「このハードウェアの素の実力」になり、後日おかしくなったときの比較対象に
# なります。
#
# 既定で走らせないのは、SSD への書き込みが発生することと、
# インストール時間が数分伸びるためです。
##############################################################################
if [[ "$BENCH" == "1" ]]; then
  step "プール性能のベースライン測定"
  BASELINE="/tmp/pool-baseline-$(date +%F).csv"
  if bash "$SCRIPT_DIR/bench-pools.sh" --yes --size "$BENCH_SIZE" --out "$BASELINE"; then
    # /mnt/root は rpool/root の上なので、インストール後もそのまま残ります。
    install -d -m 0700 /mnt/root
    install -m 0600 "$BASELINE" /mnt/root/ \
      && echo "ベースラインを /root/$(basename "$BASELINE") に保存しました。"
  else
    echo "警告: ベンチマークに失敗しました。インストールは続行します。" >&2
  fi
fi

if [[ "$FORMAT_ONLY" == "1" ]]; then
  step "--format-only 指定のためここで終了"
  echo "続行する場合:"
  echo "  nixos-install --root /mnt --flake ${FLAKE}"
  exit 0
fi

##############################################################################
# nixos-install
##############################################################################
step "nixos-install"
install_args=(--root /mnt --flake "$FLAKE")
if [[ "${PROMPT_ROOT_PASSWORD:-1}" == "1" ]]; then
  echo
  echo "※ ビルド完了後に root パスワードの入力を求められます。"
  echo "   (この値は /mnt/etc/shadow に直接書かれ、Nix ストアには残りません)"
else
  install_args+=(--no-root-passwd)
fi
nixos-install "${install_args[@]}"

##############################################################################
# 設定一式を新システムへ配置
##############################################################################
step "設定を /mnt/etc/nixos へ配置"
##############################################################################
# リポジトリを丸ごとコピーする。
#
# 以前はファイルを個別に列挙していましたが、modules/ に1枚足したときに
# ここへの追記を忘れると、インストールは成功するのに (nixos-install は
# リポジトリ側を直接読むため)、再起動後の nixos-rebuild だけが
# 「ファイルが無い」で失敗します。実際にこれを踏みました。
#
# .git は除外します。flake のソースツリーとして必要ないうえ、
# /etc/nixos に履歴ごと置くと肥大化するためです
# (バージョン管理は手元のリポジトリ側で行う)。
##############################################################################
install -d -m 0755 /mnt/etc/nixos
tar -C "$REPO_DIR" --exclude=.git --exclude=result -cf - . \
  | tar -C /mnt/etc/nixos -xf - \
  || die "/mnt/etc/nixos へのコピーに失敗しました。"

# root 所有・一般ユーザーは読めるだけにする (パスワードハッシュを含みうるため)
chown -R root:root /mnt/etc/nixos
find /mnt/etc/nixos -type d -exec chmod 0755 {} +
find /mnt/etc/nixos -type f -exec chmod 0644 {} +
find /mnt/etc/nixos -type f -name '*.sh' -exec chmod 0755 {} +

echo "--- /mnt/etc/nixos に配置したファイル ---"
find /mnt/etc/nixos -type f | sed 's|/mnt/etc/nixos/|  |' | sort

##############################################################################
# プールのクリーンエクスポート
#
# 非クリーンな停止のマークを消してから再起動するための処理。
#
# このスクリプトは disko を動かす前に ISO の /etc/hostid を最終的な hostId に
# 揃えてあるので、export し損ねても hostid 不一致にはなりません。
# それでも export するのは、ZFS が「まだ他ホストが使用中」と判断する余地を
# 完全に無くしておくためです。
# (保険は三重: hostid の事前一致 / ここでの export / forceImportRoot = true)
##############################################################################
if [[ "${NO_EXPORT:-0}" != "1" ]]; then
  step "プールをクリーンにエクスポート"
  sync
  umount -R /mnt || die "/mnt のアンマウントに失敗しました。/mnt を使っているプロセスがないか確認してください (lsof +D /mnt)。"
  swapoff -a || true
  if zpool export -a; then
    echo "OK — rpool / dpool をエクスポートしました。安全に再起動できます。"
  else
    echo "警告: zpool export に失敗しました。" >&2
    echo "      このまま再起動すると hostid 不一致でインポートを拒否される可能性があります。" >&2
    echo "      (boot.zfs.forceImportRoot = true なので通常は起動できますが、" >&2
    echo "       手動で  zpool export -a  を成功させてから再起動するのが安全です)" >&2
    zpool status || true
  fi
fi

##############################################################################
step "完了"

if [[ -z "${USER_PASSWORD_HASH:-}" ]]; then
  cat <<EOF

★初回起動後にやること★
  コンソールで root としてログイン (パスワードは先ほど設定したもの) し、
  通常ユーザーのパスワードを設定してください:

    passwd $USER_NAME

EOF
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
  cat <<EOF
SSH で入れるようにするには、初回起動後に公開鍵を足します:

    vi /etc/nixos/machine.nix     # userSshKeys = [ "ssh-ed25519 AAAA..." ];
    nixos-rebuild switch --flake /etc/nixos

EOF
fi

cat <<EOF

インストールが完了しました。ログ: $LOG

再起動:
  reboot
$( [[ "${NO_EXPORT:-0}" == "1" ]] && echo "  (--no-export 指定のため、先に umount -R /mnt && swapoff -a && zpool export -a が必要)" )

再起動後の確認:
  zpool status -v
  zpool list -v
  arc_summary            # ARC の状況
  smartctl -a /dev/nvme0 # SSD の寿命 (Percentage Used) と温度

以後の運用:
  sudo nixos-rebuild switch --flake /etc/nixos

ディスク障害からの再構築:
  同じ flake で  disko --mode destroy,format,mount --flake /etc/nixos#${HOSTNAME}
  を流せば同じレイアウトが再現されます (machine.nix の by-id は要更新)。
EOF
