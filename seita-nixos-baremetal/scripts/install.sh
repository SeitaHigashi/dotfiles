#!/usr/bin/env bash
#
# NixOS on ZFS all-in-one installer (disko-based)
#   1x SSD (EFI + swap + slog reservation + rpool) + 2x HDD mirror (dpool)
#
# Assumes: booted from the NixOS installer ISO, connected via SSH as root.
#
#   !!! The contents of the 3 specified disks will be completely erased !!!
#
# Usage:
#   1. Edit scripts/disks.env for your environment
#   2. bash scripts/install.sh
#
# Partitioning, pool creation, dataset creation and mounting are all done by
# disko from the declarations in disko/default.nix. This script's job is only:
#   disks.env -> machine.nix generation, pre-flight checks, and kicking off
#   disko and nixos-install.
#
# Options:
#   --yes              Don't prompt for confirmation (fully unattended)
#   --no-tmux          Don't auto re-exec into tmux
#   --config-only      Stop after generating machine.nix and dry-run eval. Disks untouched
#   --format-only      Stop after disko formats/mounts. Don't run nixos-install
#   --skip-format      Don't run disko (assumes /mnt is already mounted, for resuming)
#   --remount          Mount the existing pools without destroying them, then
#                       run nixos-install. Use this when redoing the install
#                       while keeping the data
#   --no-export        Don't umount /mnt and zpool export at the end
#                      (normally leave this unset — forgetting to export can leave
#                       the system unbootable)
#   --list-disks       List this machine's disks and by-id paths, then exit
#   --bench            Measure a performance baseline right after pool creation
#                       and save it under /root (takes a few minutes; size is
#                       configurable via --bench-size)
#   --bench-size <N>   Benchmark test size (default 4G)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# FLAKE is decided after disks.env is sourced (the flake attribute name = hostname).
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

# Only --bench-size takes a value, so we track the previous argument as we loop.
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
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

##############################################################################
# Run inside tmux so the install doesn't die if the SSH connection drops
##############################################################################
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" \
      && "${NIXOS_ZFS_IN_TMUX:-0}" != "1" && "$NO_TMUX" != "1" ]]; then
  if command -v tmux >/dev/null 2>&1; then
    echo "Detected an SSH session. Running inside tmux 'nixos-install'."
    echo "If disconnected, reconnect and run:  tmux attach -t nixos-install"
    sleep 2
    export NIXOS_ZFS_IN_TMUX=1
    exec tmux new-session -A -s nixos-install -- "${BASH_SOURCE[0]}" "$@"
  else
    echo "WARNING: running over SSH outside tmux/screen."
    echo "         If disconnected, the install will be interrupted."
    echo "         Recommended: enter a shell with nix-shell -p tmux first."
    if [[ "$ASSUME_YES" != "1" ]]; then
      read -r -p "Continue anyway? [y/N]: " a
      [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
    fi
  fi
fi

# Decide where to log.
#   ★ Never place this inside $REPO_DIR (the flake's source tree) ★
#   nix eval / nixos-install hash the entire directory passed to --flake as a
#   NAR to use as input, so if the log keeps growing inside it during the run,
#   the directory contents keep changing and the hash computed at first eval
#   ends up mismatching the hash read later, failing with "NAR hash mismatch"
#   (this has actually happened in practice).
# If /tmp isn't writable (permissions, read-only, etc.), fall back to $HOME
# (outside the repo), and if that also fails, continue without a log. The log
# is only a convenience, so it should never block the install.
if ! ( : >> "$LOG" ) 2>/dev/null; then
  LOG="${HOME:-/root}/nixos-zfs-install.log"
  ( : >> "$LOG" ) 2>/dev/null || LOG=""
fi
if [[ -n "$LOG" ]]; then
  exec > >(tee -a "$LOG") 2>&1
  echo "===== $(date -Is) install.sh (disko) starting (log: $LOG) ====="
else
  echo "===== $(date -Is) install.sh (disko) starting (no writable log, screen only) ====="
fi

# Flakes are disabled by default on the installer ISO, so enable them just for this run.
export NIX_CONFIG="experimental-features = nix-command flakes"

# shellcheck source=disks.env
source "$SCRIPT_DIR/disks.env"

# The flake's configuration name matches the hostname (flake.nix reads
# hostName from machine.nix). This lets you drop the attribute name after
# install and just write:
#   sudo nixos-rebuild switch --flake /etc/nixos
#
# Note: HOSTNAME is a variable bash itself sets to the currently running
# machine's hostname. If disks.env has no HOSTNAME= line, the ISO's hostname
# ("nixos") gets used silently and the configuration name ends up wrong. An
# emptiness check alone wouldn't catch this, so we check that disks.env
# actually defines it.
grep -qE '^[[:space:]]*HOSTNAME=' "$SCRIPT_DIR/disks.env" \
  || { echo "ERROR: disks.env has no HOSTNAME= line." >&2; exit 1; }
[[ -n "${HOSTNAME:-}" ]] \
  || { echo "ERROR: HOSTNAME is empty." >&2; exit 1; }
FLAKE="${REPO_DIR}#${HOSTNAME}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==================== $* ===================="; }

# Print a pasteable candidate list when the disk settings are wrong.
list_disks() {
  echo
  echo "--- Disks on this machine ---"
  lsblk -dno NAME,SIZE,ROTA,MODEL | while read -r name size rota model; do
    if [[ "$rota" == "1" ]]; then kind="HDD"; else kind="SSD/NVMe"; fi
    printf '  /dev/%-10s %-8s %-9s %s\n' "$name" "$size" "$kind" "$model"
  done
  echo
  echo "--- by-id paths to paste into disks.env (partitions excluded) ---"
  for l in /dev/disk/by-id/*; do
    [[ -L "$l" ]] || continue
    case "$l" in *-part*) continue ;; esac
    tgt="$(readlink -f "$l")"
    [[ -b "$tgt" ]] || continue
    # Only print entries backed by a real device like /dev/sda, with size.
    printf '  %-12s %s\n' "$(lsblk -dno SIZE "$tgt" 2>/dev/null)" "$l"
  done | sort -u
  echo
  echo "  (nvme-Model_Serial / ata-Model_Serial forms are more readable than wwn-...)"
}

if [[ "$LIST_DISKS" == "1" ]]; then
  list_disks
  exit 0
fi

##############################################################################
# Pre-flight checks
##############################################################################
step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] || die "Please run as root (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This configuration requires systemd-boot (UEFI)."

missing=()
for c in nix nixos-generate-config nixos-install zpool zfs; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[[ ${#missing[@]} -eq 0 ]] || die "Commands not found: ${missing[*]}"

modprobe zfs 2>/dev/null || true
zpool version >/dev/null 2>&1 || die "The ZFS kernel module isn't usable. Boot from a ZFS-enabled ISO."

bad=0
for v in SSD HDD1 HDD2; do
  d="${!v}"
  if [[ "$d" == *XXXXXXX* || "$d" == *YYYYYYY* ]]; then
    echo "ERROR: $v is still the disks.env template value: $d" >&2
    bad=1
  elif [[ ! -b "$d" ]]; then
    echo "ERROR: $v has no matching block device: $d" >&2
    bad=1
  fi
done
if [[ "$bad" == "1" ]]; then
  list_disks
  die "Rewrite SSD / HDD1 / HDD2 in $SCRIPT_DIR/disks.env using the by-id paths above."
fi
[[ "$(readlink -f "$SSD")"  != "$(readlink -f "$HDD1")" ]] || die "SSD and HDD1 are the same device."
[[ "$(readlink -f "$SSD")"  != "$(readlink -f "$HDD2")" ]] || die "SSD and HDD2 are the same device."
[[ "$(readlink -f "$HDD1")" != "$(readlink -f "$HDD2")" ]] || die "HDD1 and HDD2 are the same device."

case "$NIX_POOL" in rpool|dpool) ;; *) die "NIX_POOL must be rpool or dpool (currently: $NIX_POOL)" ;; esac
case "${USE_SLOG:-0}" in 0|1) ;; *) die "USE_SLOG must be 0 or 1 (currently: $USE_SLOG)" ;; esac

sz1=$(blockdev --getsize64 "$HDD1"); sz2=$(blockdev --getsize64 "$HDD2")
if [[ "$sz1" != "$sz2" ]]; then
  echo "WARNING: the HDDs have different capacities ($((sz1/1000/1000/1000))GB / $((sz2/1000/1000/1000))GB)."
  echo "         The mirror will use the smaller capacity."
fi

# Needed to fetch disko and nixpkgs, and for nixos-install's binary cache
curl -fsS -m 15 -o /dev/null https://cache.nixos.org/nix-cache-info \
  || die "Can't reach cache.nixos.org. Check the network configuration."

##############################################################################
# Generating machine.nix
##############################################################################
step "Determining machine-specific values"

if [[ -z "${HOST_ID:-}" ]]; then
  HOST_ID="$(head -c 8 /etc/machine-id)"
  echo "Generated hostId from /etc/machine-id: $HOST_ID"
else
  echo "hostId (from disks.env): $HOST_ID"
fi
[[ "$HOST_ID" =~ ^[0-9a-fA-F]{8}$ ]] || die "hostId isn't an 8-digit hex value: $HOST_ID"

##############################################################################
# ★ Align the ISO's hostid with the value the installed system will use ★
#
# ZFS stamps the "hostid of the creating host" into the pool label at
# creation time. If we don't do anything here, the ISO's hostid gets stamped
# in, which will always differ from the installed system's
# networking.hostId. Then, the moment there's an unclean shutdown (crash,
# power loss, kernel panic), stage 1 will refuse to boot next time with:
#   cannot import 'dpool': pool was previously in use from another system
#
# By aligning the ISO's /etc/hostid beforehand, the pool gets stamped with
# the final hostid from the start, and this failure path never opens up.
# (This is a more fundamental defense than boot.zfs.forceImportRoot = true,
# which only covers a forgotten export.)
#
# The hostid's actual value doesn't matter (it's fine for it to differ per
# ISO boot). What matters is only that the value stamped into the pool
# matches the installed system's networking.hostId. Setting the ISO side to
# the same value as machine.nix here guarantees that.
#
# /etc/hostid is 4 bytes, little-endian. "5a8a0885" -> 85 08 8a 5a.
#
# On the ISO, /etc/hostid can be a symlink into the nix store via
# /etc/static/..., so redirecting into it directly would try to write to the
# (read-only) store and fail. Remove the link first, then create a real file.
##############################################################################
h="${HOST_ID,,}"
rm -f /etc/hostid
printf "\\x${h:6:2}\\x${h:4:2}\\x${h:2:2}\\x${h:0:2}" > /etc/hostid \
  || die "Failed to write /etc/hostid (check that /etc is writable)."
actual_hostid="$(hostid)"
[[ "$actual_hostid" == "$h" ]] \
  || die "Failed to set hostid (expected: $h / actual: $actual_hostid)."
echo "Set the ISO's hostid to $h (this value will be stamped into the pool)"
unset h actual_hostid

# SSH public key: disks.env takes priority; otherwise carry over authorized_keys from the ISO.
# configuration.nix has PasswordAuthentication = false, so getting this wrong
# locks you out after reboot.
keys_raw="${SSH_AUTHORIZED_KEYS:-}"
if [[ -z "$keys_raw" ]]; then
  for f in /root/.ssh/authorized_keys "$HOME/.ssh/authorized_keys"; do
    [[ -r "$f" ]] && keys_raw+="$(cat "$f")"$'\n'
  done
fi
mapfile -t SSH_KEYS < <(printf '%s\n' "$keys_raw" | sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' | sort -u)

# Sanity-check the password hash shape.
# Double-quoting in disks.env would let bash expand $y$... and corrupt it, so
# stop here if it doesn't look like a crypt-format hash.
for v in USER_PASSWORD_HASH ROOT_PASSWORD_HASH; do
  h="${!v:-}"
  [[ -z "$h" ]] && continue
  if [[ ! "$h" =~ ^\$[0-9a-zA-Z]+\$ ]]; then
    die "$v doesn't look like a crypt-format hash: '$h'
       Wrap it in single quotes in disks.env (double quotes let \$ expand and corrupt it).
         OK : $v='\$y\$j9T\$...'
         NG : $v=\"\$y\$j9T\$...\"
       Generate with:  nix-shell -p mkpasswd --run 'mkpasswd -m yescrypt'"
  fi
  # Also rejects an accidental plaintext password (non-crypt-format already dies above, but just in case)
  echo "$v: format OK (${h:0:6}...)"
done

echo "SSH public keys carried over: ${#SSH_KEYS[@]}"
for k in "${SSH_KEYS[@]}"; do echo "  ${k%% *} ... ${k##* }"; done

# Prevent ending up with zero login methods. Options are:
#   1) SSH public key
#   2) A password hash baked into machine.nix (note: this stays in the Nix store)
#   3) The interactive root password nixos-install asks for at the end (written directly to /etc/shadow)
if [[ "${PROMPT_ROOT_PASSWORD:-1}" == "1" ]]; then
  echo "Root password: will be set interactively at the end of nixos-install (written directly to /etc/shadow, not kept in the Nix store)"
  if [[ -z "${USER_PASSWORD_HASH:-}" ]]; then
    echo "  -> ${USER_NAME}'s password is not set. After first boot, log in as root on"
    echo "     the console and run: passwd ${USER_NAME}"
  fi
elif [[ ${#SSH_KEYS[@]} -eq 0 && -z "${USER_PASSWORD_HASH:-}" && -z "${ROOT_PASSWORD_HASH:-}" ]]; then
  echo
  echo "WARNING: there are no login methods at all."
  echo "         PROMPT_ROOT_PASSWORD=0 and neither an SSH public key nor a password hash is set."
  echo "         You will not be able to log in after reboot."
  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Continue anyway? [y/N]: " a
    [[ "$a" == "y" || "$a" == "Y" ]] || exit 1
  fi
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
  echo "Note: 0 SSH public keys, so you won't be able to SSH in after reboot (console only)."
  echo "      Add one later to userSshKeys in /etc/nixos/machine.nix and run"
  echo "      nixos-rebuild switch to enable it."
fi

step "Generating machine.nix"
nix_str() { # Prints null or a "string" (escaped as a Nix string)
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
  echo '# Auto-generated by scripts/install.sh from scripts/disks.env.'
  echo "# Generated at: $(date -Is)"
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
# Hardware configuration detection
#   --no-filesystems: don't generate fileSystems / swapDevices.
#   Those are generated by disko instead, and would clash if present.
##############################################################################
step "Detecting hardware configuration"
nixos-generate-config --no-filesystems --show-hardware-config > "$REPO_DIR/hardware-configuration.nix"
echo "--- hardware-configuration.nix ---"
cat "$REPO_DIR/hardware-configuration.nix"
echo "----------------------------------"

##############################################################################
# Dry-run evaluation (catch syntax/eval errors before touching disks)
##############################################################################
step "Evaluating configuration (dry run)"
# Catch Nix syntax/eval errors here, before touching any disks.
nix eval --raw \
  "${REPO_DIR}#nixosConfigurations.\"${HOSTNAME}\".config.system.build.toplevel.drvPath" >/dev/null \
  || die "Evaluating the system configuration failed. Check the error above."
echo "OK — system configuration"

nix eval --raw \
  "${REPO_DIR}#nixosConfigurations.\"${HOSTNAME}\".config.system.build.diskoScript" >/dev/null \
  || die "Evaluating the disko layout failed. Check disko/default.nix."
echo "OK — disko layout"

##############################################################################
# Final confirmation
##############################################################################
step "Confirming what will happen"
cat <<EOF
  Hostname       : $HOSTNAME  (hostId: $HOST_ID)
  User           : $USER_NAME
  /nix location  : $NIX_POOL  $( [[ "$NIX_POOL" == dpool ]] && echo "(HDD — saves SSD writes; build/GC run at HDD speed)" || echo "(SSD)" )
  ARC limit      : $((ARC_MAX_BYTES/1024/1024/1024)) GiB
  SLOG           : $( [[ "${USE_SLOG:-0}" == 1 ]] && echo "enabled" || echo "disabled (part3 is reserved only)" )

  Disks to be erased:
    SSD  $SSD
         -> $(readlink -f "$SSD")   $(lsblk -dno SIZE,MODEL "$(readlink -f "$SSD")")
    HDD1 $HDD1
         -> $(readlink -f "$HDD1")  $(lsblk -dno SIZE,MODEL "$(readlink -f "$HDD1")")
    HDD2 $HDD2
         -> $(readlink -f "$HDD2")  $(lsblk -dno SIZE,MODEL "$(readlink -f "$HDD2")")

  SSD: EFI ${EFI_SIZE} / swap ${SWAP_SIZE} / slog ${SLOG_SIZE} / remainder to rpool
  HDD: mirror (100% in a single partition)
EOF

if [[ "$CONFIG_ONLY" == "1" ]]; then
  step "Stopping here due to --config-only (disks not touched)"
  echo "To continue:"
  echo "  nix run github:nix-community/disko/latest -- --mode destroy,format,mount --flake ${FLAKE}"
  echo "  nixos-install --root /mnt --flake ${FLAKE}"
  exit 0
fi

# Only prompt for confirmation when destroy,format,mount will actually run.
# --skip-format / --remount keep the existing pools, so skip the prompt.
if [[ "$ASSUME_YES" != "1" && "$SKIP_FORMAT" != "1" && "$REMOUNT" != "1" ]]; then
  echo
  read -r -p "This will erase the 3 disks listed above. Type 'YES' to continue: " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
elif [[ "$REMOUNT" == "1" ]]; then
  echo
  echo "--remount specified: the existing pool and data will NOT be destroyed (mounting only)."
fi

##############################################################################
# disko: destroy -> format -> mount
##############################################################################
if [[ "$REMOUNT" == "1" ]]; then
  # Mount the existing pool without destroying it.
  # Use this when redoing nixos-install but keeping the pool and its data as-is.
  step "Remounting via disko (--remount / existing pool not destroyed)"
  mountpoint -q /mnt && { umount -R /mnt || die "Failed to unmount /mnt."; }

  nix run github:nix-community/disko/latest -- \
    --mode mount \
    --flake "$FLAKE"

elif [[ "$SKIP_FORMAT" != "1" ]]; then
  step "Partitioning, creating pools, and mounting via disko"

  # If a leftover pool exists, disko will decide "it already exists, don't
  # create it" — so clean up manually before entering destroy mode.
  mountpoint -q /mnt && umount -R /mnt || true
  swapoff -a || true
  for p in rpool dpool; do
    if zpool list "$p" >/dev/null 2>&1; then
      echo "Destroying existing pool '$p'."
      zpool destroy -f "$p" || zpool export -f "$p" || true
    fi
  done
  # ZFS labels also exist at the end of the disk, so clear those too
  for d in "$SSD"* "$HDD1"* "$HDD2"*; do
    [[ -b "$d" ]] && zpool labelclear -f "$d" >/dev/null 2>&1 || true
  done

  nix run github:nix-community/disko/latest -- \
    --mode destroy,format,mount \
    --flake "$FLAKE"
else
  step "Skipping disko (--skip-format)"
  mountpoint -q /mnt || die "/mnt is not mounted.
       If the pool has already been created and you want to remount and resume,
       use --remount instead:
         sudo bash $0 --remount"
fi

step "Mount results"
zpool status
echo
zpool list -v
echo
findmnt -R /mnt

##############################################################################
# Pool performance baseline measurement (only with --bench)
#
# Right after pool creation, before anything is stored on it, is the best
# time to measure this (no fragmentation, no snapshots, no other I/O). The
# values captured here become "this hardware's raw capability" and the
# comparison point for later if something looks off.
#
# Not run by default because it writes to the SSD and extends the install
# by several minutes.
##############################################################################
if [[ "$BENCH" == "1" ]]; then
  step "Measuring pool performance baseline"
  BASELINE="/tmp/pool-baseline-$(date +%F).csv"
  if bash "$SCRIPT_DIR/bench-pools.sh" --yes --size "$BENCH_SIZE" --out "$BASELINE"; then
    # /mnt/root sits on rpool/root, so it survives after install too.
    install -d -m 0700 /mnt/root
    install -m 0600 "$BASELINE" /mnt/root/ \
      && echo "Saved the baseline to /root/$(basename "$BASELINE")."
  else
    echo "WARNING: the benchmark failed. Continuing with the install." >&2
  fi
fi

if [[ "$FORMAT_ONLY" == "1" ]]; then
  step "Stopping here due to --format-only"
  echo "To continue:"
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
  echo "Note: you'll be asked for the root password once the build finishes."
  echo "      (This value is written directly to /mnt/etc/shadow, not kept in the Nix store)"
else
  install_args+=(--no-root-passwd)
fi
nixos-install "${install_args[@]}"

##############################################################################
# Deploy the full configuration onto the new system
##############################################################################
step "Deploying configuration to /mnt/etc/nixos"
##############################################################################
# Copy the whole repository.
#
# This used to list files individually, but forgetting to add an entry here
# when adding a file under modules/ meant the install would succeed (since
# nixos-install reads directly from the repo) while a later nixos-rebuild
# after reboot would fail with "file not found". This has actually happened.
#
# .git is excluded: it isn't needed as the flake's source tree, and keeping
# the full history under /etc/nixos would bloat it unnecessarily
# (version control stays on the local repo copy).
##############################################################################
install -d -m 0755 /mnt/etc/nixos
tar -C "$REPO_DIR" --exclude=.git --exclude=result -cf - . \
  | tar -C /mnt/etc/nixos -xf - \
  || die "Failed to copy files to /mnt/etc/nixos."

# Owned by root; regular users can only read (may contain password hashes)
chown -R root:root /mnt/etc/nixos
find /mnt/etc/nixos -type d -exec chmod 0755 {} +
find /mnt/etc/nixos -type f -exec chmod 0644 {} +
find /mnt/etc/nixos -type f -name '*.sh' -exec chmod 0755 {} +

echo "--- Files deployed to /mnt/etc/nixos ---"
find /mnt/etc/nixos -type f | sed 's|/mnt/etc/nixos/|  |' | sort

##############################################################################
# Clean pool export
#
# Clears the "unclean shutdown" marker before rebooting.
#
# This script has already aligned the ISO's /etc/hostid with the final
# hostId before running disko, so failing to export here won't cause a
# hostid mismatch. We still export anyway to leave zero room for ZFS to
# think "another host might still be using this".
# (Triple safety net: matching hostid up front / export here / forceImportRoot = true)
##############################################################################
if [[ "${NO_EXPORT:-0}" != "1" ]]; then
  step "Cleanly exporting the pools"
  sync
  umount -R /mnt || die "Failed to unmount /mnt. Check for processes still using it (lsof +D /mnt)."
  swapoff -a || true
  if zpool export -a; then
    echo "OK — exported rpool / dpool. Safe to reboot."
  else
    echo "WARNING: zpool export failed." >&2
    echo "         Rebooting now may have the import refused due to a hostid mismatch." >&2
    echo "         (boot.zfs.forceImportRoot = true usually lets it boot anyway, but" >&2
    echo "          it's safer to run  zpool export -a  manually until it succeeds first)" >&2
    zpool status || true
  fi
fi

##############################################################################
step "Done"

if [[ -z "${USER_PASSWORD_HASH:-}" ]]; then
  cat <<EOF

★Things to do after first boot★
  Log in as root on the console (using the password you just set), and
  set the regular user's password:

    passwd $USER_NAME

EOF
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
  cat <<EOF
To be able to log in over SSH, add a public key after first boot:

    vi /etc/nixos/machine.nix     # userSshKeys = [ "ssh-ed25519 AAAA..." ];
    nixos-rebuild switch --flake /etc/nixos

EOF
fi

cat <<EOF

Installation complete. Log: $LOG

Reboot:
  reboot
$( [[ "${NO_EXPORT:-0}" == "1" ]] && echo "  (--no-export was specified, so first run umount -R /mnt && swapoff -a && zpool export -a)" )

Checks after reboot:
  zpool status -v
  zpool list -v
  arc_summary            # ARC status
  smartctl -a /dev/nvme0 # SSD lifetime (Percentage Used) and temperature

Ongoing operation:
  sudo nixos-rebuild switch --flake /etc/nixos

Rebuilding after a disk failure:
  Running  disko --mode destroy,format,mount --flake /etc/nixos#${HOSTNAME}
  with the same flake reproduces the same layout (update the by-id paths in
  machine.nix first).
EOF
