#!/usr/bin/env bash
#
# rpool (SSD) と dpool (HDD mirror) の性能を測り、
# 「このハードウェアなら出て当然の値」と比較して評価する。
#
# ZFS はそのまま測ると ARC (RAM キャッシュ) と圧縮が効いてしまい、
# 「RAM の速度」や「ゼロ埋めの圧縮率」を測ることになります。そこで
#   - 測定専用データセットを作り compression=off にする
#   - primarycache=none (キャッシュ無効) と all (通常運用) の両方で測る
# という形にしています。cached 側は「二度目以降のアクセス」、
# uncached 側は「実際のディスク性能」だと思ってください。
#
# 判定は、プールを構成するデバイスが回転体かどうか (/sys の rotational) を
# 見て自動で切り替わります。SSD と HDD に同じ基準を当てても意味がないためです。
#
# 使い方:
#   sudo bash scripts/bench-pools.sh                       # 測定して評価
#   sudo bash scripts/bench-pools.sh --out baseline.csv    # 結果を保存
#   sudo bash scripts/bench-pools.sh --compare baseline.csv # 過去と比較
#   sudo bash scripts/bench-pools.sh --pools dpool --seq-only
#
# オプション:
#   --size <N>      テストファイルサイズ (既定 4G)
#   --pools <list>  対象プール (既定 "rpool dpool")
#   --seq-only      シーケンシャルのみ。HDD のランダムは遅いので時短用
#   --out <file>    結果を CSV で保存する (ベースライン記録用)
#   --compare <f>   保存済み CSV と比較して増減を表示する
#   --keep          測定用データセットを消さずに残す
#   --yes           確認プロンプトを出さない
#
#   !!! 注意 !!!
#   実際にディスクへ書き込みます。SSD の寿命を消費します。
#   実行前後の Percentage Used を自動で表示します。
#
set -euo pipefail

SIZE="4G"
POOLS="rpool dpool"
SEQ_ONLY=0
KEEP=0
ASSUME_YES=0
OUT=""
COMPARE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)     SIZE="$2"; shift 2 ;;
    --pools)    POOLS="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --compare)  COMPARE="$2"; shift 2 ;;
    --seq-only) SEQ_ONLY=1; shift ;;
    --keep)     KEEP=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==================== $* ===================="; }

[[ "$(id -u)" -eq 0 ]] || die "root で実行してください (sudo bash $0)。"
command -v zfs >/dev/null 2>&1 || die "zfs コマンドが見つかりません。"

##############################################################################
# fio / jq の用意
#
# environment.systemPackages には入れていないので、無ければ nix shell で借ります。
# jq が無いと数値を取り出せず評価ができないため、両方まとめて借ります。
##############################################################################
if ! command -v fio >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "fio / jq が見つかりません。nix shell で一時的に借ります..."
  args=( --size "$SIZE" --pools "$POOLS" )
  ((SEQ_ONLY))   && args+=( --seq-only )
  ((KEEP))       && args+=( --keep )
  ((ASSUME_YES)) && args+=( --yes )
  [[ -n "$OUT" ]]     && args+=( --out "$OUT" )
  [[ -n "$COMPARE" ]] && args+=( --compare "$COMPARE" )
  exec nix shell nixpkgs#fio nixpkgs#jq --command bash "${BASH_SOURCE[0]}" "${args[@]}"
fi

##############################################################################
# 期待値
#
# 「このハードウェアなら最低でもこれくらいは出るはず」という下限です。
# 製品スペックのピーク値ではなく、ZFS 越し・単一ジョブでの現実的な値に
# 寄せてあります。カタログ値と比べると低く見えますが、それが正常です。
#
#   seq-*  … MiB/s
#   rand-* … IOPS
#
# 値の根拠:
#   ssd  … DRAM 搭載 NVMe (PCIe 3.0 以上) を想定。PCIe 3.0 x4 の実効上限が
#           約 3.5 GB/s なので、世代が古くても下限は割らない水準に設定。
#   hdd  … 7200rpm 級 2台の mirror を想定。mirror は読みを分散できるので
#           シーケンシャル読みは 1台ぶんの 1.5〜2 倍まで伸びる。
#           書き込みは分散できないので 1台ぶんが上限。
##############################################################################
declare -A EXPECT_GOOD EXPECT_WARN

# --- SSD (非回転体) ---
EXPECT_GOOD["ssd:seq-write"]=800   ; EXPECT_WARN["ssd:seq-write"]=300
EXPECT_GOOD["ssd:seq-read"]=1000   ; EXPECT_WARN["ssd:seq-read"]=400
EXPECT_GOOD["ssd:rand-write"]=20000; EXPECT_WARN["ssd:rand-write"]=5000
EXPECT_GOOD["ssd:rand-read"]=30000 ; EXPECT_WARN["ssd:rand-read"]=8000

# --- HDD (回転体) ---
EXPECT_GOOD["hdd:seq-write"]=100   ; EXPECT_WARN["hdd:seq-write"]=50
EXPECT_GOOD["hdd:seq-read"]=150    ; EXPECT_WARN["hdd:seq-read"]=80
EXPECT_GOOD["hdd:rand-write"]=300  ; EXPECT_WARN["hdd:rand-write"]=100
EXPECT_GOOD["hdd:rand-read"]=200   ; EXPECT_WARN["hdd:rand-read"]=80

##############################################################################
# プールが SSD か HDD かを判定する
#
# zpool status -P で構成デバイスのフルパスを取り、lsblk の ROTA (rotational) を
# 見ます。1つでも回転体があれば HDD 扱いにします (遅い方が律速するため)。
##############################################################################
pool_kind() {
  local pool="$1" dev kind="ssd"
  while read -r dev; do
    [[ -b "$dev" ]] || continue
    if [[ "$(lsblk -dno ROTA "$dev" 2>/dev/null | tr -d ' ')" == "1" ]]; then
      kind="hdd"
    fi
  done < <(zpool status -P "$pool" 2>/dev/null | grep -oE '/dev/[^ ]+')
  echo "$kind"
}

##############################################################################
# 事前確認
##############################################################################
step "測定前の状態"

for p in $POOLS; do
  zpool list -H -o name "$p" >/dev/null 2>&1 || die "プール '$p' が見つかりません。"
  echo "  $p … $(pool_kind "$p") として評価します"
done
echo
zpool list -v $POOLS || true

echo
echo "--- ARC ---"
awk '/^(c_max|c|size) /{printf "  %-8s %s MiB\n", $1, int($3/1024/1024)}' \
  /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo "  (arcstats を読めません)"

smart_summary() {
  for d in /dev/nvme?n1 /dev/nvme?; do
    [[ -e "$d" ]] || continue
    if smartctl -A "$d" >/dev/null 2>&1; then
      echo "  $d"
      smartctl -A "$d" | grep -iE "percentage used|data units written|temperature:" | sed 's/^/    /'
      break
    fi
  done
}
echo
echo "--- SSD の寿命 (測定前) ---"
if command -v smartctl >/dev/null 2>&1; then smart_summary; else echo "  (smartctl 無し)"; fi

if [[ "$ASSUME_YES" != "1" ]]; then
  echo
  echo "対象プール: $POOLS / テストサイズ: $SIZE"
  echo "ディスクへ実際に書き込みます (SSD の寿命を消費します)。"
  read -r -p "続行しますか? [y/N]: " a
  [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
fi

##############################################################################
# 測定用データセットの作成 / 後片付け
##############################################################################
CREATED=()
RESULTS=()   # "pool,phase,test,mib,iops,p99ms"

cleanup() {
  if ((KEEP)); then
    echo
    echo "--keep 指定のため測定用データセットを残しました:"
    printf '  %s\n' "${CREATED[@]}"
    return
  fi
  for ds in "${CREATED[@]:-}"; do
    [[ -n "$ds" ]] || continue
    zfs destroy -r "$ds" 2>/dev/null || echo "警告: $ds を削除できませんでした" >&2
  done
}
trap cleanup EXIT

# 作成したマウントポイントは BENCH_MNT に入れる。
# $(mk_dataset ...) と書くとサブシェルになり CREATED への追記が親に届かないので、
# グローバル変数経由で受け渡すこと。
BENCH_MNT=""
mk_dataset() {
  local pool="$1" ds="$1/bench" mnt="/bench-$1"
  zfs list -H -o name "$ds" >/dev/null 2>&1 && zfs destroy -r "$ds"
  # compression=off … fio のデータが圧縮されて実性能が測れなくなるのを防ぐ
  zfs create \
    -o mountpoint="$mnt" \
    -o compression=off \
    -o "com.sun:auto-snapshot=false" \
    -o recordsize=1M \
    "$ds"
  CREATED+=("$ds")
  BENCH_MNT="$mnt"
}

##############################################################################
# fio 実行
#
#   run_fio <テスト名> <ディレクトリ> <rw> <ブロックサイズ> <並列数>
#
# ioengine=psync では iodepth が効かないため、並列度は numjobs で作ります。
# --end_fsync=1 で書き込みは最後に必ず同期させます (省くと遅延書き込みのぶん
# 速く見えます)。
#
# 結果は RES_MIB / RES_IOPS / RES_P99 に入ります。
##############################################################################
RES_MIB=0; RES_IOPS=0; RES_P99=0
run_fio() {
  local name="$1" dir="$2" rw="$3" bs="$4" jobs="$5" out
  RES_MIB=0; RES_IOPS=0; RES_P99=0

  out="$(fio \
    --name="$name" \
    --directory="$dir" \
    --rw="$rw" \
    --bs="$bs" \
    --size="$SIZE" \
    --numjobs="$jobs" \
    --ioengine=psync \
    --end_fsync=1 \
    --group_reporting \
    --output-format=json 2>/dev/null)" || return 1

  read -r RES_MIB RES_IOPS RES_P99 < <(echo "$out" | jq -r '
    .jobs[0] as $j
    | (if $j.read.bw_bytes > 0 then $j.read else $j.write end) as $r
    | "\($r.bw_bytes/1048576 | floor) \($r.iops | floor) \((($r.clat_ns.percentile["99.000000"] // 0)/1000000) | floor)"')
}

##############################################################################
# 評価
#
#   report <プール> <種別 ssd|hdd> <フェーズ> <テスト名> <指標 mib|iops>
#
# 期待値と比べて OK / 注意 / 低い の3段階で判定します。
# 期待値表に無いもの (cached の読み込みなど) は判定せず数値だけ出します。
##############################################################################
report() {
  local pool="$1" kind="$2" phase="$3" test="$4" metric="$5"
  local key="$kind:$test" value verdict="" note=""

  if [[ "$metric" == "mib" ]]; then value="$RES_MIB"; else value="$RES_IOPS"; fi

  if [[ -n "${EXPECT_GOOD[$key]:-}" && "$phase" != "cached" ]]; then
    if   (( value >= EXPECT_GOOD[$key] )); then verdict="OK"
    elif (( value >= EXPECT_WARN[$key] )); then verdict="注意"
    else                                        verdict="低い"
    fi
    note=" (期待 >= ${EXPECT_GOOD[$key]})"
  fi

  printf '    %-16s %6s MiB/s  %8s IOPS  p99 %4s ms  %s%s\n' \
    "$test" "$RES_MIB" "$RES_IOPS" "$RES_P99" "$verdict" "$note"

  RESULTS+=("$pool,$phase,$test,$RES_MIB,$RES_IOPS,$RES_P99")
}

##############################################################################
# 1プール分の測定
##############################################################################
bench_pool() {
  local pool="$1" kind
  kind="$(pool_kind "$pool")"
  step "$pool の測定 ($kind として評価)"

  mk_dataset "$pool"
  local mnt="$BENCH_MNT" ds="$pool/bench"

  echo
  echo "  [1] 書き込み (キャッシュの影響を受けない)"
  run_fio "seq-write" "$mnt" write 1M 1 && report "$pool" "$kind" write "seq-write" mib
  if ! ((SEQ_ONLY)); then
    zfs set recordsize=16K "$ds"
    run_fio "rand-write" "$mnt" randwrite 16K 4 && report "$pool" "$kind" write "rand-write" iops
    zfs set recordsize=1M "$ds"
  fi

  echo
  echo "  [2] 読み込み — uncached (primarycache=none = 実ディスク性能)"
  zfs set primarycache=none "$ds"
  run_fio "seq-read" "$mnt" read 1M 1 && report "$pool" "$kind" uncached "seq-read" mib
  if ! ((SEQ_ONLY)); then
    run_fio "rand-read" "$mnt" randread 16K 4 && report "$pool" "$kind" uncached "rand-read" iops
  fi

  echo
  echo "  [3] 読み込み — cached (primarycache=all = 二度目以降の体感)"
  zfs set primarycache=all "$ds"
  cat "$mnt"/* > /dev/null 2>&1 || true
  run_fio "seq-read" "$mnt" read 1M 1 && report "$pool" "$kind" cached "seq-read" mib
  if ! ((SEQ_ONLY)); then
    run_fio "rand-read" "$mnt" randread 16K 4 && report "$pool" "$kind" cached "rand-read" iops
  fi
}

for p in $POOLS; do
  bench_pool "$p"
done

##############################################################################
# 結果の保存 / 過去との比較
##############################################################################
if [[ -n "$OUT" ]]; then
  {
    echo "# nixos-zfs pool benchmark $(date -Is) size=$SIZE"
    echo "pool,phase,test,mib,iops,p99ms"
    printf '%s\n' "${RESULTS[@]}"
  } > "$OUT"
  echo
  echo "結果を $OUT に保存しました。"
  echo "次回  --compare $OUT  を付けると増減を確認できます。"
fi

if [[ -n "$COMPARE" ]]; then
  step "過去の測定との比較"
  if [[ ! -r "$COMPARE" ]]; then
    echo "  $COMPARE を読めません。比較をスキップします。"
  else
    printf '  %-8s %-9s %-12s %10s %10s %8s\n' プール フェーズ テスト 前回 今回 増減
    for line in "${RESULTS[@]}"; do
      IFS=, read -r pool phase test mib iops _ <<< "$line"
      old="$(grep -E "^$pool,$phase,$test," "$COMPARE" | head -1 || true)"
      [[ -n "$old" ]] || continue
      IFS=, read -r _ _ _ omib oiops _ <<< "$old"
      # シーケンシャルは MiB/s、ランダムは IOPS で比べる
      if [[ "$test" == seq-* ]]; then new="$mib"; prev="$omib"; else new="$iops"; prev="$oiops"; fi
      if (( prev > 0 )); then diff=$(( (new - prev) * 100 / prev )); else diff=0; fi
      printf '  %-8s %-9s %-12s %10s %10s %7s%%\n' "$pool" "$phase" "$test" "$prev" "$new" "$diff"
    done
    echo
    echo "  -20% を超える低下が続く場合、断片化 (プールの使用率が高い)、"
    echo "  ディスクの劣化、スクラブ/リシルバの同時実行などを疑ってください。"
  fi
fi

##############################################################################
# 測定後
##############################################################################
step "測定後の状態"

echo "--- SSD の寿命 (測定後) ---"
if command -v smartctl >/dev/null 2>&1; then smart_summary; else echo "  (smartctl 無し)"; fi

echo
echo "--- NVMe のエラー (測定中に脱落していないか) ---"
if journalctl -k --since "-30 min" 2>/dev/null | grep -iE "nvme.*(timeout|reset controller|I/O error)"; then
  echo
  echo "  ★ 測定中に NVMe が脱落しています。これは性能ではなく安定性の問題です。"
  echo "    数値が良くても、この行が出ている時点で本番投入してはいけません。"
  echo "    README の「障害事例: NVMe 脱落による起動不能」を参照してください。"
else
  echo "  なし (正常)"
fi

echo
echo "読み方:"
echo "  判定は [1] 書き込みと [2] uncached にだけ付きます。"
echo "  [3] cached は ARC の速度なので、ディスクの評価には使いません。"
echo "  「低い」が出た場合に疑うもの:"
echo "    - ashift が実セクタサイズと不一致 (作成後は変更不可)"
echo "    - HDD が SMR (連続書き込みで数 MB/s まで落ちる)"
echo "    - PCIe のレーン数・世代が想定より低い (lspci -vv で確認)"
echo "    - スクラブ / リシルバ / スナップショット削除が同時に走っている"
echo "  [3] が [2] と大差ないなら ARC に載りきっていません。"
echo "  --size を減らすか arcMaxBytes を増やして再測定してください。"
