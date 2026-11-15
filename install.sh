#!/usr/bin/env bash
# AshFall installer for the Retroid Pocket 5.
#
# One command, three phases, no build tools:
#   1. verify the download against the checksums pinned in this repo,
#   2. flash the AshFall system image (fastbootd),
#   3. flash the GPU vendor_boot + verification-off vbmeta in ONE bootloader
#      batch (the RP5 bootloader wedges when fastboot opens between transfers),
#      then reboot.
#
# Usage:
#   ./install.sh                  # install the version pinned in ./VERSION
#   ./install.sh --check          # preflight only, no downloads, no writes
#   ./install.sh --dry-run        # download + verify, print the plan, no writes
#   ./install.sh --wipe           # erase userdata/metadata too (clean install)
#   ./install.sh --no-oc          # keep the stock vendor_boot (no GPU overclock)
#   ./install.sh --release TAG    # install another pinned release (rollback)
#   ./install.sh --serial SERIAL  # pick a device when several are attached
#   ./install.sh --yes            # do not ask for confirmation
#   ./install.sh --fresh-download # ignore files already in ./ashfall-download
#   ./install.sh --help
#
# Requirements: adb + fastboot (Android platform-tools), gh (logged in with
# access to the release repo), xz, sha256sum or shasum.
#
# Safety: refuses a non-RP5, a locked bootloader and a battery below 30 %,
# writes only system_<slot>, vendor_boot and vbmeta, never wipes unless --wipe
# is given, and verifies every file against the checksums committed in
# releases/<tag>/SHA256SUMS before anything reaches the device.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO="ashfall-rom/ashfall-install"
VERSION_FILE="$HERE/VERSION"
DL_ROOT="$HERE/ashfall-download"

TAG=""
SERIAL=""
WIPE=0
OC=1
ASSUME_YES=0
DRY_RUN=0
CHECK_ONLY=0
FRESH=0

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf ' ok %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*" >&2; }
die() { printf '\nerr %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"; }

while (($#)); do
  case $1 in
    --check) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --wipe) WIPE=1; shift ;;
    --no-oc) OC=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --fresh-download) FRESH=1; shift ;;
    --release) TAG=${2:?--release needs a tag}; shift 2 ;;
    --serial) SERIAL=${2:?--serial needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -n $TAG ]] || TAG=$(tr -d ' \n' <"$VERSION_FILE" 2>/dev/null || true)
[[ -n $TAG ]] || die "no release tag: missing $VERSION_FILE and no --release"
SUM_FILE="$HERE/releases/$TAG/SHA256SUMS"
[[ -f $SUM_FILE ]] || die "no checksums for '$TAG' in this checkout (releases/$TAG/SHA256SUMS); git pull, or pass a tag it knows"
DL="$DL_ROOT/$TAG"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_one() {
  local name=$1 want got
  want=$(awk -v n="$name" '$2==n{print $1; exit}' "$SUM_FILE")
  [[ -n $want ]] || die "no checksum for $name in $SUM_FILE (bad checkout)"
  got=$(sha256_file "$DL/$name")
  [[ $got == "$want" ]] || die "checksum mismatch for $name ($got != $want). Delete $DL and run again: a corrupted download must never be flashed."
  ok "$name verified"
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 ||
      die "missing '$c'. Install Android platform-tools and gh (macOS: brew install android-platform-tools gh; Debian/Ubuntu: apt install adb fastboot gh)"
  done
}

# --- preflight ---------------------------------------------------------------
step "Checking the device"
need adb fastboot
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
  die "need sha256sum or shasum to verify the download"

ADB_DEVICES=()
while IFS= read -r line; do ADB_DEVICES+=("$line"); done < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
if [[ -n $SERIAL ]]; then
  case " ${ADB_DEVICES[*]:-} " in
    *" $SERIAL "*) : ;;
    *) die "device '$SERIAL' is not attached (adb devices: ${ADB_DEVICES[*]:-none})" ;;
  esac
else
  case ${#ADB_DEVICES[@]} in
    0) die "no device found. Connect the RP5, enable USB debugging, accept the prompt on the device (adb devices must list it)" ;;
    1) SERIAL=${ADB_DEVICES[0]} ;;
    *) die "several devices attached (${ADB_DEVICES[*]}); pick one with --serial" ;;
  esac
fi

adb_() { adb -s "$SERIAL" "$@"; }
fb_() { fastboot -s "$SERIAL" "$@"; }

PLATFORM=$(adb_ shell getprop ro.board.platform 2>/dev/null | tr -d '\r')
[[ $PLATFORM == kona ]] || die "this is not a Retroid Pocket 5 (ro.board.platform='${PLATFORM:-unknown}', expected 'kona'). Nothing was written."
BATTERY=$(adb_ shell dumpsys battery 2>/dev/null | awk -F': ' '/level/{print $2; exit}' | tr -d '\r')
if [[ ${BATTERY:-0} =~ ^[0-9]+$ ]] && ((BATTERY < 30)); then
  die "battery is ${BATTERY}%; charge to at least 30% before flashing"
fi
CUR_SLOT=$(adb_ shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
ok "Retroid Pocket 5 (kona), battery ${BATTERY:-unknown}%, slot ${CUR_SLOT:-unknown}, serial $SERIAL"

if ((CHECK_ONLY)); then
  step "Preflight only"
  say "release:   $TAG"
  say "checksums: $SUM_FILE"
  say "would flash: system image$( ((OC)) && printf ' + GPU vendor_boot')$([[ $WIPE == 1 ]] && printf ' + wipe userdata/metadata')"
  ok "ready (nothing was downloaded or written)"
  exit 0
fi

# --- download + verify -------------------------------------------------------
step "Fetching AshFall $TAG"
mkdir -p "$DL"
if ((FRESH)); then
  rm -f "$DL/system.img.xz" "$DL/system.img" "$DL/vendor_boot.img" "$DL/vbmeta.img"
fi

ASSETS=(system.img.xz vbmeta.img)
((OC)) && ASSETS+=(vendor_boot.img)
MISSING=()
for a in "${ASSETS[@]}"; do [[ -f $DL/$a ]] || MISSING+=("$a"); done
if ((${#MISSING[@]})); then
  command -v gh >/dev/null 2>&1 ||
    die "missing ${MISSING[*]} in $DL and gh is not installed. Download them from https://github.com/$REPO/releases/tag/$TAG into $DL and re-run"
  gh auth status >/dev/null 2>&1 ||
    die "gh is not logged in. Run 'gh auth login' (the release repo is private), or download ${MISSING[*]} from https://github.com/$REPO/releases/tag/$TAG into $DL and re-run"
  say "downloading ${MISSING[*]} from $REPO@$TAG"
  for a in "${MISSING[@]}"; do
    gh release download "$TAG" --repo "$REPO" --pattern "$a" --dir "$DL" --clobber ||
      die "cannot download $a from $REPO@$TAG"
  done
fi

step "Verifying the download"
verify_one system.img.xz
((OC)) && verify_one vendor_boot.img
verify_one vbmeta.img

if [[ ! -f $DL/system.img ]]; then
  command -v xz >/dev/null 2>&1 ||
    die "xz is required to unpack system.img.xz (macOS: brew install xz; Debian/Ubuntu: apt install xz-utils), or unpack it yourself into $DL/system.img"
  NEED_KB=$(xz --robot --list "$DL/system.img.xz" 2>/dev/null | awk '$1=="totals"{print int($5/1024)+262144; exit}')
  [[ ${NEED_KB:-} =~ ^[0-9]+$ ]] || NEED_KB=3145728
  FREE_KB=$(df -Pk "$DL" | awk 'NR==2{print $4}')
  ((FREE_KB > NEED_KB)) ||
    die "not enough disk space in $DL: need about $((NEED_KB / 1024)) MB free"
  say "unpacking system.img.xz (~$((NEED_KB / 1024)) MB)"
  xz -dc "$DL/system.img.xz" >"$DL/system.img.tmp"
  mv "$DL/system.img.tmp" "$DL/system.img"
fi
verify_one system.img
ok "system image ready ($(du -h "$DL/system.img" | awk '{print $1}'))"

# --- plan --------------------------------------------------------------------
step "Plan"
say "  release:      $TAG  (repo $REPO)"
say "  device:       Retroid Pocket 5, serial $SERIAL, slot ${CUR_SLOT:-unknown}"
say "  system:       $DL/system.img"
if ((OC)); then
  say "  GPU:          vendor_boot from the pinned release (1000/940/850/765 MHz available, stock cap by default)"
else
  say "  GPU:          stock vendor_boot kept (no overclock)"
fi
say "  boot:         verification off (vbmeta flags=3, required for a GSI)"
say "  data:         $([[ $WIPE == 1 ]] && echo 'ERASED (--wipe)' || echo 'kept')"
say ""
say "  The device reboots twice and runs two flashes. Do not unplug it, do not touch buttons."
if ((!ASSUME_YES)); then
  printf '\nContinue? [y/N] '
  read -r answer
  case $answer in y|Y|yes) : ;; *) die "aborted by the user" ;; esac
fi
if ((DRY_RUN)); then
  ok "dry run: nothing was written to the device"
  exit 0
fi

# --- phase 1: system image (fastbootd) --------------------------------------
step "Phase 1/2: system image (fastbootd)"
adb_ reboot fastboot
MODE=""
for ((i = 0; i < 120; i++)); do
  MODE=$(fb_ getvar is-userspace 2>&1 || true)
  printf '%s' "$MODE" | grep -q 'is-userspace: yes' && break
  sleep 1
done
printf '%s' "$MODE" | grep -q 'is-userspace: yes' ||
  die "the device did not reach fastbootd. Unplug and re-plug the USB cable, then re-run; see docs/recovery.md if it repeats"
SLOT=$(fb_ getvar current-slot 2>&1 | sed -n 's/^current-slot: //p' | head -1)
case $SLOT in a|b) : ;; *) die "unexpected current slot '${SLOT:-empty}'" ;; esac
ok "fastbootd, slot $SLOT"

say "flashing system_$SLOT ($(du -h "$DL/system.img" | awk '{print $1}')) - this takes a few minutes"
if ! fb_ flash "system_$SLOT" "$DL/system.img"; then
  die "system flash failed. If it mentions space, free the stock product partition and re-run:
       fastboot -s $SERIAL delete-logical-partition product_$SLOT
       fastboot -s $SERIAL delete-logical-partition system_ext_$SLOT
   Nothing else is touched; see docs/recovery.md"
fi
ok "system_$SLOT flashed"

# --- phase 2: bootloader (vendor_boot + vbmeta + optional wipe) -------------
# One fastboot process for the whole bootloader-side batch: the RP5 ABL wedges
# when a new fastboot opens between transfers (issue #54).
step "Phase 2/2: bootloader (vbmeta$( ((OC)) && echo ', vendor_boot')$([[ $WIPE == 1 ]] && echo ', wipe'))"
fb_ reboot bootloader || warn "fastboot reboot bootloader failed; trying adb"
for ((i = 0; i < 90; i++)); do
  fb_ devices 2>/dev/null | grep -q "$SERIAL" && break
  sleep 1
done
if ! fb_ devices 2>/dev/null | grep -q "$SERIAL"; then
  # Fallback path when fastbootd cannot jump to the bootloader: let Android
  # come up (the old system is still installed and bootable) and reboot from
  # there. Never needed on a healthy device.
  warn "bootloader not reached from fastbootd; rebooting to Android and retrying"
  adb_ wait-for-device >/dev/null 2>&1 || true
  for ((i = 0; i < 120; i++)); do
    adb_ shell getprop sys.boot_completed 2>/dev/null | grep -q '^1' && break
    sleep 2
  done
  adb_ reboot bootloader
  for ((i = 0; i < 90; i++)); do
    fb_ devices 2>/dev/null | grep -q "$SERIAL" && break
    sleep 1
  done
fi
fb_ devices 2>/dev/null | grep -q "$SERIAL" ||
  die "device did not reach the bootloader. Hold Power 15 s, then Power+Volume Down, and re-run; see docs/recovery.md"

PRODUCT=$(fb_ getvar product 2>&1 | sed -e 's/^(bootloader)[[:space:]]*//' -n 's/^product: //p' | head -1)
UNLOCKED=$(fb_ getvar unlocked 2>&1 | sed -e 's/^(bootloader)[[:space:]]*//' -n 's/^unlocked: //p' | head -1)
[[ $PRODUCT == kona ]] || die "bootloader reports product '${PRODUCT:-unknown}', expected 'kona'"
[[ $UNLOCKED == yes ]] ||
  die "the bootloader is locked. Unlock it first: adb reboot bootloader && fastboot flashing unlock, confirm on the device (this erases data), then re-run"
ok "bootloader: kona, unlocked"

BATCH=(--disable-verity --disable-verification flash vbmeta "$DL/vbmeta.img")
if ((OC)); then
  BATCH+=(flash vendor_boot "$DL/vendor_boot.img")
fi
if ((WIPE)); then
  BATCH+=(erase userdata erase metadata)
fi
BATCH+=(reboot)
say "one fastboot process: fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img ... reboot"
fb_ "${BATCH[@]}" ||
  die "the bootloader flash failed. Do NOT unplug: run 'fastboot -s $SERIAL reboot' (or hold Power 15 s), then re-run the installer"
ok "bootloader writes done"

step "Waiting for AshFall to boot"
for ((i = 0; i < 300; i++)); do
  adb_ shell getprop sys.boot_completed 2>/dev/null | grep -q '^1' && break
  sleep 2
done
if adb_ shell getprop sys.boot_completed 2>/dev/null | grep -q '^1'; then
  ok "AshFall $TAG is installed and running"
  say ""
  say "  Settings -> AshFall settings: fan, lighting, controller, power"
  say "  The GPU cap stays at stock 670 MHz; the overclock is opt-in there."
else
  warn "the device has not reported boot_completed yet. The first boot can take up to 5 minutes."
  warn "If it stays on the boot animation: most often stale /data from another ROM, so re-run with --wipe."
  warn "Recovery and restore-stock steps: docs/recovery.md"
fi
