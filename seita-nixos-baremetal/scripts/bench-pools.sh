#!/usr/bin/env bash
#
# Measure rpool (SSD) and dpool (HDD mirror) performance and evaluate it
# against "what this hardware should be capable of".
#
# Measuring ZFS as-is would be affected by ARC (RAM cache) and compression,
# ending up measuring "RAM speed" or "zero-fill compression ratio" instead.
# To avoid that, this script:
#   - creates a dedicated dataset for measurement with compression=off
#   - measures with both primarycache=none (cache disabled) and all (normal use)
# The cached side represents "access on a second-or-later pass"; the
# uncached side represents "actual disk performance".
#
# The judgment thresholds switch automatically based on whether the pool's
# devices are rotational (checked via /sys), since the same bar doesn't make
# sense for SSD vs HDD.
#
# Usage:
#   sudo bash scripts/bench-pools.sh                       # measure and evaluate
#   sudo bash scripts/bench-pools.sh --out baseline.csv    # save the results
#   sudo bash scripts/bench-pools.sh --compare baseline.csv # compare against a past run
#   sudo bash scripts/bench-pools.sh --pools dpool --seq-only
#
# Options:
#   --size <N>      Test file size (default 4G)
#   --pools <list>  Target pools (default "rpool dpool")
#   --seq-only      Sequential only. Saves time since HDD random is slow
#   --out <file>    Save the results as CSV (for recording a baseline)
#   --compare <f>   Compare against a saved CSV and show the delta
#   --keep          Don't delete the measurement dataset afterwards
#   --yes           Don't prompt for confirmation
#
#   !!! WARNING !!!
#   This actually writes to the disks. It consumes SSD lifetime.
#   Percentage Used is shown automatically before and after the run.
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
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==================== $* ===================="; }

[[ "$(id -u)" -eq 0 ]] || die "Please run as root (sudo bash $0)."
command -v zfs >/dev/null 2>&1 || die "zfs command not found."

##############################################################################
# Getting fio / jq
#
# These aren't in environment.systemPackages, so borrow them via nix shell
# if missing. jq is needed to extract the numbers for evaluation, so both
# are borrowed together.
##############################################################################
if ! command -v fio >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "fio / jq not found. Borrowing them via nix shell..."
  args=( --size "$SIZE" --pools "$POOLS" )
  ((SEQ_ONLY))   && args+=( --seq-only )
  ((KEEP))       && args+=( --keep )
  ((ASSUME_YES)) && args+=( --yes )
  [[ -n "$OUT" ]]     && args+=( --out "$OUT" )
  [[ -n "$COMPARE" ]] && args+=( --compare "$COMPARE" )
  exec nix shell nixpkgs#fio nixpkgs#jq --command bash "${BASH_SOURCE[0]}" "${args[@]}"
fi

##############################################################################
# Expected values
#
# These are lower bounds — "this hardware should manage at least this much" —
# not peak spec-sheet numbers. They're set to realistic values through ZFS
# with a single job, rather than catalog numbers, so they look low next to a
# spec sheet; that's expected.
#
#   seq-*  … MiB/s
#   rand-* … IOPS
#
# Basis for the values:
#   ssd  … assumes a DRAM-equipped NVMe drive (PCIe 3.0 or newer). PCIe 3.0
#           x4's effective ceiling is about 3.5 GB/s, so the lower bound is
#           set low enough not to be tripped even by an older generation.
#   hdd  … assumes a mirror of two 7200rpm-class drives. A mirror can spread
#           reads across both disks, so sequential read can reach 1.5-2x a
#           single drive. Writes can't be spread, so a single drive's rate
#           is the ceiling.
##############################################################################
declare -A EXPECT_GOOD EXPECT_WARN

# --- SSD (non-rotational) ---
EXPECT_GOOD["ssd:seq-write"]=800   ; EXPECT_WARN["ssd:seq-write"]=300
EXPECT_GOOD["ssd:seq-read"]=1000   ; EXPECT_WARN["ssd:seq-read"]=400
EXPECT_GOOD["ssd:rand-write"]=20000; EXPECT_WARN["ssd:rand-write"]=5000
EXPECT_GOOD["ssd:rand-read"]=30000 ; EXPECT_WARN["ssd:rand-read"]=8000

# --- HDD (rotational) ---
EXPECT_GOOD["hdd:seq-write"]=100   ; EXPECT_WARN["hdd:seq-write"]=50
EXPECT_GOOD["hdd:seq-read"]=150    ; EXPECT_WARN["hdd:seq-read"]=80
EXPECT_GOOD["hdd:rand-write"]=300  ; EXPECT_WARN["hdd:rand-write"]=100
EXPECT_GOOD["hdd:rand-read"]=200   ; EXPECT_WARN["hdd:rand-read"]=80

##############################################################################
# Determine whether a pool is SSD or HDD
#
# Gets the full paths of the pool's member devices via zpool status -P, and
# checks lsblk's ROTA (rotational) flag. If any device is rotational, treat
# the whole pool as HDD (the slowest device is the bottleneck).
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
# Pre-flight checks
##############################################################################
step "State before measurement"

for p in $POOLS; do
  zpool list -H -o name "$p" >/dev/null 2>&1 || die "Pool '$p' not found."
  echo "  $p … evaluating as $(pool_kind "$p")"
done
echo
zpool list -v $POOLS || true

echo
echo "--- ARC ---"
awk '/^(c_max|c|size) /{printf "  %-8s %s MiB\n", $1, int($3/1024/1024)}' \
  /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo "  (cannot read arcstats)"

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
echo "--- SSD lifetime (before measurement) ---"
if command -v smartctl >/dev/null 2>&1; then smart_summary; else echo "  (smartctl not found)"; fi

if [[ "$ASSUME_YES" != "1" ]]; then
  echo
  echo "Target pools: $POOLS / Test size: $SIZE"
  echo "This will actually write to the disks (consumes SSD lifetime)."
  read -r -p "Continue? [y/N]: " a
  [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
fi

##############################################################################
# Creating / cleaning up the measurement dataset
##############################################################################
CREATED=()
RESULTS=()   # "pool,phase,test,mib,iops,p99ms"

cleanup() {
  if ((KEEP)); then
    echo
    echo "--keep specified, leaving the measurement dataset(s) in place:"
    printf '  %s\n' "${CREATED[@]}"
    return
  fi
  for ds in "${CREATED[@]:-}"; do
    [[ -n "$ds" ]] || continue
    zfs destroy -r "$ds" 2>/dev/null || echo "WARNING: failed to delete $ds" >&2
  done
}
trap cleanup EXIT

# The created mount point is passed via BENCH_MNT.
# Writing $(mk_dataset ...) would run it in a subshell, so the append to
# CREATED wouldn't reach the parent shell — pass it back via a global instead.
BENCH_MNT=""
mk_dataset() {
  local pool="$1" ds="$1/bench" mnt="/bench-$1"
  zfs list -H -o name "$ds" >/dev/null 2>&1 && zfs destroy -r "$ds"
  # compression=off … prevents fio's data from compressing and skewing real performance
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
# Running fio
#
#   run_fio <test name> <directory> <rw> <block size> <parallelism>
#
# With ioengine=psync, iodepth has no effect, so parallelism comes from
# numjobs instead. --end_fsync=1 forces writes to be synced at the end
# (omitting it would look faster due to delayed writeback).
#
# Results land in RES_MIB / RES_IOPS / RES_P99.
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
# Evaluation
#
#   report <pool> <kind ssd|hdd> <phase> <test name> <metric mib|iops>
#
# Compares against the expected value and reports OK / warn / low.
# Anything not in the expectation table (e.g. cached reads) is reported
# without a verdict, numbers only.
##############################################################################
report() {
  local pool="$1" kind="$2" phase="$3" test="$4" metric="$5"
  local key="$kind:$test" value verdict="" note=""

  if [[ "$metric" == "mib" ]]; then value="$RES_MIB"; else value="$RES_IOPS"; fi

  if [[ -n "${EXPECT_GOOD[$key]:-}" && "$phase" != "cached" ]]; then
    if   (( value >= EXPECT_GOOD[$key] )); then verdict="OK"
    elif (( value >= EXPECT_WARN[$key] )); then verdict="warn"
    else                                        verdict="low"
    fi
    note=" (expected >= ${EXPECT_GOOD[$key]})"
  fi

  printf '    %-16s %6s MiB/s  %8s IOPS  p99 %4s ms  %s%s\n' \
    "$test" "$RES_MIB" "$RES_IOPS" "$RES_P99" "$verdict" "$note"

  RESULTS+=("$pool,$phase,$test,$RES_MIB,$RES_IOPS,$RES_P99")
}

##############################################################################
# Measuring a single pool
##############################################################################
bench_pool() {
  local pool="$1" kind
  kind="$(pool_kind "$pool")"
  step "Measuring $pool (evaluated as $kind)"

  mk_dataset "$pool"
  local mnt="$BENCH_MNT" ds="$pool/bench"

  echo
  echo "  [1] Write (unaffected by cache)"
  run_fio "seq-write" "$mnt" write 1M 1 && report "$pool" "$kind" write "seq-write" mib
  if ! ((SEQ_ONLY)); then
    zfs set recordsize=16K "$ds"
    run_fio "rand-write" "$mnt" randwrite 16K 4 && report "$pool" "$kind" write "rand-write" iops
    zfs set recordsize=1M "$ds"
  fi

  echo
  echo "  [2] Read — uncached (primarycache=none = actual disk performance)"
  zfs set primarycache=none "$ds"
  run_fio "seq-read" "$mnt" read 1M 1 && report "$pool" "$kind" uncached "seq-read" mib
  if ! ((SEQ_ONLY)); then
    run_fio "rand-read" "$mnt" randread 16K 4 && report "$pool" "$kind" uncached "rand-read" iops
  fi

  echo
  echo "  [3] Read — cached (primarycache=all = subsequent-access experience)"
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
# Saving results / comparing with a past run
##############################################################################
if [[ -n "$OUT" ]]; then
  {
    echo "# nixos-zfs pool benchmark $(date -Is) size=$SIZE"
    echo "pool,phase,test,mib,iops,p99ms"
    printf '%s\n' "${RESULTS[@]}"
  } > "$OUT"
  echo
  echo "Saved the results to $OUT."
  echo "Pass --compare $OUT next time to see the delta."
fi

if [[ -n "$COMPARE" ]]; then
  step "Comparing with a past measurement"
  if [[ ! -r "$COMPARE" ]]; then
    echo "  Cannot read $COMPARE. Skipping the comparison."
  else
    printf '  %-8s %-9s %-12s %10s %10s %8s\n' pool phase test previous current delta
    for line in "${RESULTS[@]}"; do
      IFS=, read -r pool phase test mib iops _ <<< "$line"
      old="$(grep -E "^$pool,$phase,$test," "$COMPARE" | head -1 || true)"
      [[ -n "$old" ]] || continue
      IFS=, read -r _ _ _ omib oiops _ <<< "$old"
      # Sequential is compared by MiB/s, random by IOPS
      if [[ "$test" == seq-* ]]; then new="$mib"; prev="$omib"; else new="$iops"; prev="$oiops"; fi
      if (( prev > 0 )); then diff=$(( (new - prev) * 100 / prev )); else diff=0; fi
      printf '  %-8s %-9s %-12s %10s %10s %7s%%\n' "$pool" "$phase" "$test" "$prev" "$new" "$diff"
    done
    echo
    echo "  If a drop of more than -20% persists, suspect fragmentation (pool usage"
    echo "  is high), disk degradation, or a concurrent scrub/resilver."
  fi
fi

##############################################################################
# After measurement
##############################################################################
step "State after measurement"

echo "--- SSD lifetime (after measurement) ---"
if command -v smartctl >/dev/null 2>&1; then smart_summary; else echo "  (smartctl not found)"; fi

echo
echo "--- NVMe errors (did the drive drop out during measurement?) ---"
if journalctl -k --since "-30 min" 2>/dev/null | grep -iE "nvme.*(timeout|reset controller|I/O error)"; then
  echo
  echo "  ★ The NVMe dropped out during measurement. This is a stability problem, not a performance one."
  echo "    Even if the numbers look good, don't put this into production while this line appears."
  echo "    See the runbook's \"Incident: unbootable after NVMe dropout\" section."
else
  echo "  none (normal)"
fi

echo
echo "How to read this:"
echo "  Verdicts only apply to [1] write and [2] uncached."
echo "  [3] cached is ARC speed, not useful for evaluating the disk."
echo "  If you see \"low\", suspect:"
echo "    - ashift mismatched against the real sector size (cannot change after creation)"
echo "    - the HDD is SMR (drops to a few MB/s under sustained writes)"
echo "    - fewer PCIe lanes/an older generation than expected (check with lspci -vv)"
echo "    - a concurrent scrub / resilver / snapshot deletion"
echo "  If [3] isn't much higher than [2], the data set doesn't fit in ARC."
echo "  Reduce --size or increase arcMaxBytes and re-measure."
