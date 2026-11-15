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
#   ./install.sh --resume         # phase 1 (system) already flashed: redo only
#                                 # the bootloader phase
#   ./install.sh                  # erase userdata + metadata and install
#   ./install.sh --wipe           # accepted for compatibility; data is always
#                                 # erased
#   ./install.sh --no-oc          # keep the stock vendor_boot (no GPU overclock)
#   ./install.sh --migrate        # force the stock .31 base install (repair;
#                                 # wipes data) even if the base looks right
#   ./install.sh --no-migrate     # never touch the base firmware (refuse on retail)
#   ./install.sh --stock          # restore the stock .31 system only (wipes
#                                 # data), then stop - same as restore-stock.sh
#   ./install.sh --rescue         # from the bootloader only: rewrite the
#                                 # complete stock .31 base (wipes data). Works
#                                 # when Android/fastbootd are dead.
#   ./install.sh --stock --then-install
#                                 # restore .31, wait for USB debugging to come
#                                 # back, then install AshFall in the same run
#   --wait-debug SECONDS          # how long --then-install waits (default 1200)
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
# writes only system_<slot>, vendor_boot and vbmeta, always erases userdata +
# metadata (a no-wipe install from stock leaves foreign /data and breaks
# features), and verifies every file against the checksums committed in
# releases/<tag>/SHA256SUMS before anything reaches the device.
set -euo pipefail
# Never die silently: any unhandled non-zero status prints the failing command.
trap 'rc=$?; printf "\nerr unexpected failure (exit %s) at line %s: %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO="ashfall-rom/ashfall-install"
VERSION_FILE="$HERE/VERSION"
DL_ROOT="$HERE/ashfall-download"

# --- the stock .31 base ------------------------------------------------------
# AshFall is an Android 17 GSI and needs the Android 13 / 5.15 vendor of the
# pre-release .31 firmware. A retail RP5 ships .189 (Android 11 vendor, 4.19
# kernel, VINTF level 5) which cannot run it, so the installer replaces the
# base first. That is a full stock-firmware flash from the public Retroid
# package: pinned part hashes, pinned image hashes, one fastboot process.
FW_URL="https://github.com/TheGammaSqueeze/Retroid_Pocket_Stock_Firmware/releases/download/Android13_RP5_V1.0.0.31_20241026_190102_user/Android13_RP5_V1.0.0.31_20241026_190102_user.7z"
FW_VOLUMES=(001 002 003 004 005)
FW_VOL_SHA=(
  4b7ef49daf0912ee91d4478c2b95be13bfa9ff8a3247ba491abc54e2523cab2c
  229a1e2b2aa5dada1eb3ead0486f51d17bbfa353c91fea8d7be291cd335f4675
  3460fb5e997cc006d0e9b515d3fe99ab2524a56c5cea39c3d118976bb636d50f
  aabeafe32b2ad8ab213e81db7fc831c8a296e9fab050e305911e2e33191b7204
  7739eaed4ad6d0e8676cdec1720f053f794e73e8045dd86ba39c47b74be0e173
)
FW_VOL_SIZE=(734003200 734003200 734003200 734003200 182108376)
# <path in the 7z>|<partition>|<bytes>|<sha256>
FW_IMAGES=(
  "flash/lun0_super.bin|super|12884901888|725a2c7366c428cbfd6b08bdcb71e55a04d3373cc2364bc16d930292191eb84d"
  "flash/lun4_boot_a.bin|boot|100663296|153d567f415f54dc5f0a08bdb521b070611d13893eaf7959aa410317b026e899"
  "flash/lun4_init_boot_a.bin|init_boot|8388608|6880d7dcbd444d7a529e89b93692243203c159041b61961735c40e983bea0018"
  "flash/lun4_vendor_boot_a.bin|vendor_boot|100663296|c6e497410af928da86344edf8ffb491651fc79b3a82c130403249b48a1c6d2f4"
  "flash/lun4_dtbo_a.bin|dtbo|25165824|51b5d76bfddd7141ba1f96eb951d48d50ef4a654c324a0c1eb67d8f99013081a"
  "flash/lun4_vbmeta_a.bin|vbmeta|65536|1e12f714ce4b89ad092df348d1469d92808f2f8535ca68900da53cd5634e7e3b"
  "flash/lun0_vbmeta_system_a.bin|vbmeta_system_a|65536|cd445c6a36cf7e6331a9c0c0da80be9d7246fd941651b077606cdddb01757e5d"
  "flash/lun4_recovery_a.bin|recovery_a|104857600|12848c7103eb285caaa01d6b51cdd8210b024c8e68cfd85b64677a0835338206"
  "flash/lun4_recovery_b.bin|recovery_b|104857600|12848c7103eb285caaa01d6b51cdd8210b024c8e68cfd85b64677a0835338206"
)
FW_DIR="$DL_ROOT/stock-31"

TAG=""
SERIAL=""
WIPE=1  # mandatory: a no-wipe install from stock breaks features
OC=1
ASSUME_YES=0
DRY_RUN=0
CHECK_ONLY=0
FRESH=0
MIGRATE=0
NO_MIGRATE=0
STOCK_ONLY=0
RESCUE=0
RESUME=0
THEN_INSTALL=0
WAIT_DEBUG=1200

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
    --migrate) MIGRATE=1; shift ;;
    --no-migrate) NO_MIGRATE=1; shift ;;
    --stock) STOCK_ONLY=1; shift ;;
    --rescue) RESCUE=1; shift ;;
    --resume) RESUME=1; shift ;;
    --then-install) THEN_INSTALL=1; shift ;;
    --wait-debug) WAIT_DEBUG=${2:?--wait-debug needs seconds}; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --fresh-download) FRESH=1; shift ;;
    --release) TAG=${2:?--release needs a tag}; shift 2 ;;
    --serial) SERIAL=${2:?--serial needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

if ((THEN_INSTALL)) && ((!STOCK_ONLY)); then
  printf 'err --then-install only makes sense with --stock\n' >&2
  exit 2
fi
if ((RESUME)) && ((RESCUE || STOCK_ONLY || MIGRATE)); then
  printf 'err --resume only resumes an interrupted install\n' >&2
  exit 2
fi
if ((RESCUE)) && ((STOCK_ONLY || MIGRATE || THEN_INSTALL)); then
  printf 'err --rescue does its own base restore; do not combine it with --stock/--migrate/--then-install\n' >&2
  exit 2
fi
[[ $WAIT_DEBUG =~ ^[0-9]+$ ]] || { printf 'err --wait-debug must be seconds\n' >&2; exit 2; }
[[ -n $TAG ]] || TAG=$(tr -d ' \n' <"$VERSION_FILE" 2>/dev/null || true)
[[ -n $TAG ]] || die "no release tag: missing $VERSION_FILE and no --release"
SUM_FILE="$HERE/releases/$TAG/SHA256SUMS"
if ((STOCK_ONLY || RESCUE)); then
  : # a stock restore / rescue does not need the AshFall release assets
else
  [[ -f $SUM_FILE ]] || die "no checksums for '$TAG' in this checkout (releases/$TAG/SHA256SUMS); git pull, or pass a tag it knows"
fi
DL="$DL_ROOT/$TAG"

stat_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then stat -c %s "$1"; else stat -f %z "$1"; fi
}

human() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
  else
    awk -v n="$1" 'BEGIN{ if (n>1073741824) printf "%.1f GiB", n/1073741824; else printf "%.0f MiB", n/1048576 }'
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# fb_batch [fastboot args...]: one fastboot process with a watchdog.
# A wedged ABL makes fastboot hang on the first transfer; without a watchdog
# the installer would wait forever instead of telling the user what to do.
FB_TIMEOUT=${ASH_FASTBOOT_TIMEOUT:-1800}
fb_batch() {
  local secs=$FB_TIMEOUT rc=0 pid wd
  local -a cmd=(fastboot)
  [[ -n $SERIAL ]] && cmd+=(-s "$SERIAL")
  cmd+=("$@")
  say "fastboot ${cmd[*]:2}   (timeout ${secs}s)"
  "${cmd[@]}" &
  pid=$!
  (
    sleep "$secs"
    if kill -0 "$pid" 2>/dev/null; then
      printf '\nwarn fastboot made no progress for %ss; the bootloader is wedged - killing the client\n' "$secs" >&2
      pkill -x fastboot 2>/dev/null || true
    fi
  ) &
  wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  return $rc
}

# fastboot_clients / guard_single_fastboot: two fastboot clients on this
# bootloader corrupt each other's replies (one client reads the other's answers:
# "GetVar Variable Not found" mixed with "unknown command", answers changing
# between sessions).  Never run a batch while another fastboot exists - the
# installer has to be the only one.
fastboot_clients() {
  local out=""
  if command -v pgrep >/dev/null 2>&1; then
    # pgrep exits 1 when nothing matches; that is the healthy case, so never let
    # it abort the script under set -e / pipefail.
    out=$(pgrep -x fastboot 2>/dev/null | tr '\n' ' ' || true)
  else
    out=$(ps -A -o comm= 2>/dev/null | awk '$1=="fastboot"{printf "%s ", $2}' || true)
  fi
  printf '%s' "$out"
}

guard_single_fastboot() {
  local pids
  pids=$(fastboot_clients || true)
  [[ -z $pids ]] || die "another fastboot process is running (PID: $pids).
       Two fastboot clients on this bootloader corrupt each other's replies -
       that is what 'GetVar Variable Not found' mixed with 'unknown command'
       means. Close the other terminal's fastboot (Ctrl-C or: pkill -x fastboot)
       and re-run."
}

# fb_probe: ONE fastboot process, informational only.  A missing variable is not
# evidence of anything, so nothing here is a hard requirement except a positive
# "unlocked: no".
FB_PRODUCT=""
FB_SLOTS=""
FB_UNLOCKED=""
fb_probe() {
  local out
  out=$(fb_ getvar product getvar slot-count getvar unlocked 2>&1 || true)
  FB_PRODUCT=$(printf '%s\n' "$out" | sed -n 's/^product: //p' | head -1)
  FB_SLOTS=$(printf '%s\n' "$out" | sed -n 's/^slot-count: //p' | head -1)
  FB_UNLOCKED=$(printf '%s\n' "$out" | sed -n 's/^unlocked: //p' | head -1)
}

# wait_for_bootloader: give the ABL time to enumerate, then check at most
# twice.  Never poll in a loop: every `fastboot devices` is a new session and
# the RP5 bootloader wedges when sessions open between transfers (issue #54).
wait_for_bootloader() {
  local i
  sleep "${ASH_BOOTLOADER_WAIT:-12}"
  for i in 1 2; do
    fb_ devices 2>/dev/null | grep -q "$SERIAL" && return 0
    sleep 5
  done
  return 1
}

# fastboot/adb wrappers (defined before any mode so --rescue works)
adb_() { adb -s "$SERIAL" "$@"; }
fb_() { fastboot -s "$SERIAL" "$@"; }
# fb_getvar <name>: value of one fastboot variable, with or without the
# "(bootloader) " prefix some ABL versions print, and with CRs stripped.
# The RP5 bootloader answers "GetVar Variable Not found" for variables that
# exist a moment later (observed repeatedly), so retry before believing an
# empty answer.
fb_getvar() {
  local var=$1 i out
  for i in 1 2 3 4 5; do
    out=$(fb_ getvar "$var" 2>&1 | tr -d '\r' |
      sed -n -e 's/^([a-z]*)[[:space:]]*//' -e "s/^$var: //p" | head -1)
    if [[ -n $out ]]; then
      printf '%s' "$out"
      return 0
    fi
    sleep 1
  done
  return 0
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

# --- stock .31 base ----------------------------------------------------------
# AshFall runs on the pre-release .31 base: Android 13 vendor, 5.15 GKI, v4
# boot. A retail .189 RP5 (Android 11 vendor, 4.19 kernel) cannot boot it, so
# the base is installed first, from the public Retroid package with every
# volume and every image hash pinned.
#
# The set below is the COMPLETE stock base, not just the partitions Android
# needs to boot:
#   * `super` - the factory image only populates slot A's dynamic partitions,
#     so the active slot must always be A after writing it (2026-11-15).
#   * `recovery` - the ROM never uses it, but `adb reboot fastboot` boots the
#     recovery ramdisk; a recovery that does not match the stock vbmeta panics
#     and strands the device in crash-dump mode. Installer versions before
#     2026-11-15 skipped it and hit exactly that.
sevenzip() {
  local c
  if [[ -n ${ASH_INSTALLER_7Z:-} ]]; then printf '%s' "$ASH_INSTALLER_7Z"; return 0; fi
  for c in 7z 7za 7zr; do
    if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# fetch_base_images: download, unpack and verify the stock base (no device
# access, so it is safe to run before anything is written).
fetch_base_images() {
  local zip free_kb need_kb i path part bytes sha img want got
  local -a paths=()

  zip=$(sevenzip) || die "7-Zip is required to unpack the stock firmware (macOS: brew install p7zip; Debian/Ubuntu: apt install p7zip-full; Windows: 7-Zip)"
  need curl
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    die "need sha256sum or shasum to verify the firmware"

  mkdir -p "$FW_DIR/parts" "$FW_DIR/images"

  need_kb=0
  for i in "${!FW_VOLUMES[@]}"; do
    f="$FW_DIR/parts/fw.7z.${FW_VOLUMES[$i]}"
    [[ -f $f && $(stat_size "$f") == "${FW_VOL_SIZE[$i]}" ]] || need_kb=$((need_kb + FW_VOL_SIZE[$i] / 1024))
  done
  need_kb=$((need_kb + 14000000))
  free_kb=$(df -Pk "$FW_DIR" | awk 'NR==2{print $4}')
  ((free_kb > need_kb)) ||
    die "not enough disk space in $FW_DIR: need about $((need_kb / 1024 / 1024)) GB free (3.1 GB download + 13.3 GB unpacked)"
  ok "disk space: $((free_kb / 1024 / 1024)) GB free, need $((need_kb / 1024 / 1024)) GB"

  step "Downloading the .31 stock firmware"
  for i in "${!FW_VOLUMES[@]}"; do
    part=${FW_VOLUMES[$i]}
    f="$FW_DIR/parts/fw.7z.$part"
    want=${FW_VOL_SIZE[$i]}
    if [[ -f $f ]] && [[ $(stat_size "$f") == "$want" ]]; then
      ok "fw.7z.$part present ($(human "$want"))"
    else
      say "downloading fw.7z.$part ($(human "$want"))"
      curl -fL -C - --retry 5 --retry-delay 5 --progress-bar \
        -o "$f" "$FW_URL.$part" || die "download failed: $FW_URL.$part (re-run to resume)"
    fi
    [[ $(stat_size "$f") == "$want" ]] || die "fw.7z.$part has the wrong size (want $want, got $(stat_size "$f"))"
    got=$(sha256_file "$f")
    [[ $got == "${FW_VOL_SHA[$i]}" ]] || die "fw.7z.$part checksum mismatch ($got != ${FW_VOL_SHA[$i]}). Delete $f and re-run."
    ok "fw.7z.$part verified"
  done

  step "Unpacking the stock images"
  for img in "${FW_IMAGES[@]}"; do
    IFS='|' read -r path part bytes sha <<<"$img"
    [[ -f $FW_DIR/images/$path ]] && [[ $(stat_size "$FW_DIR/images/$path") == "$bytes" ]] ||
      paths+=("$path")
  done
  if ((${#paths[@]})); then
    say "extracting ${#paths[@]} image(s) - this takes a few minutes"
    "$zip" x -y -o"$FW_DIR/images" "$FW_DIR/parts/fw.7z.001" "${paths[@]}" >/dev/null ||
      die "7-Zip could not unpack the firmware (is fw.7z.002..005 next to fw.7z.001?)"
  fi
  for img in "${FW_IMAGES[@]}"; do
    IFS='|' read -r path part bytes sha <<<"$img"
    f="$FW_DIR/images/$path"
    [[ -f $f ]] || die "missing $path after unpacking"
    [[ $(stat_size "$f") == "$bytes" ]] || die "$path has the wrong size (want $bytes, got $(stat_size "$f"))"
    got=$(sha256_file "$f")
    [[ $got == "$sha" ]] || die "$path checksum mismatch; delete $FW_DIR and re-run"
    ok "$part verified ($(human "$bytes"))"
  done
}

# flash_base <adb|fastboot>: one fastboot process for every base write.
#   adb      - the device is in Android; reboot to the bootloader first
#   fastboot - the device is already in the bootloader (rescue path)
flash_base() {
  local mode=$1 path part bytes sha img i
  local -a BATCH=()

  if [[ $mode == adb ]]; then
    step "Rebooting to the bootloader"
    adb_ reboot bootloader
    for ((i = 0; i < 90; i++)); do
      fb_ devices 2>/dev/null | grep -q "$SERIAL" && break
      sleep 1
    done
  fi
  fb_ devices 2>/dev/null | grep -q "$SERIAL" ||
    die "the device is not in the bootloader.
       Hold Power ~15 s, then Volume Down + Power until the fastboot screen
       appears, then re-run:  $0 --rescue${SERIAL:+ --serial $SERIAL}"

  guard_single_fastboot
  fb_probe
  if [[ $FB_UNLOCKED == no ]]; then
    die "the bootloader is locked; unlock it first (adb reboot bootloader; fastboot flashing unlock) and re-run"
  fi
  if [[ -n $FB_PRODUCT && $FB_PRODUCT != kona ]]; then
    die "the bootloader reports product '$FB_PRODUCT', expected 'kona' (wrong device?)"
  fi
  if [[ $FB_PRODUCT == kona ]]; then
    ok "bootloader: kona, unlocked=${FB_UNLOCKED:-unknown}, slots=${FB_SLOTS:-unknown}"
  else
    warn "the bootloader did not report a product; continuing (only a kona reaches this point)"
  fi

  # -S caps one download at 512 MiB, below this ABL's buffer limit and the
  # client's 4 GiB cap.  Without it a raw 12 GiB super is one download and the
  # client fails with "File is too large to download", even when the variable
  # service is healthy.
  BATCH=(-S 512M)
  for img in "${FW_IMAGES[@]}"; do
    IFS='|' read -r path part bytes sha <<<"$img"
    BATCH+=(flash "$part" "$FW_DIR/images/$path")
  done
  BATCH+=(erase userdata erase metadata)
  if [[ $FB_SLOTS == 2 ]]; then
    BATCH+=(set_active a)
  else
    warn "the bootloader did not report 2 slots; leaving the active slot unchanged"
  fi
  BATCH+=(reboot)

  say "one fastboot process: ${#FW_IMAGES[@]} flashes + wipe + set_active a + reboot"
  say "this takes 15-20 minutes; do not unplug, do not open another fastboot"
  FB_TIMEOUT=3600
  if ! fb_batch "${BATCH[@]}"; then
    die "the base flash did not finish.
       Do NOT unplug. Run: fastboot -s $SERIAL reboot   (or hold Power 15 s)
       Then re-run:  $0 --rescue
       The verified images are cached in $FW_DIR/images, so a retry is fast."
  fi
}

# migrate_base: base -> stop -> the user finishes the install in a second run.
migrate_base() {
  if ((STOCK_ONLY)); then
    step "Restore the stock .31 system"
    say "  Flashes the stock .31 firmware and wipes data. The device stays on"
    say "  stock Android 13 afterwards unless --then-install was given."
  else
    step "Base firmware: retail .189 -> AshFall base .31"
    say "  AshFall is an Android 17 system on the Android 13 / 5.15 vendor of the"
    say "  pre-release .31 firmware. This RP5 runs the retail firmware (vendor"
    say "  SDK ${VENDOR_SDK:-?}), which cannot boot it."
  fi
  say ""
  say "  The installer will install the complete stock .31 base first:"
  say "    download   3.1 GB (public Retroid package, pinned SHA-256)"
  say "    unpack     13.3 GB (super + boot chain + recovery)"
  say "    flash      super, boot, init_boot, vendor_boot, dtbo, vbmeta,"
  say "               vbmeta_system, recovery_a/b in ONE fastboot process"
  say "    wipe       userdata + metadata (all data is lost)"
  say ""
  if ((THEN_INSTALL)); then
    say "  After it finishes the device boots stock .31; the installer then waits"
    say "  for USB debugging to come back and installs AshFall in the same run."
  elif ((STOCK_ONLY)); then
    say "  After it finishes the device boots stock .31 and stays there."
  else
    say "  After it finishes the device boots stock .31. Enable USB debugging"
    say "  again and run ./install.sh to install AshFall."
  fi
  say ""

  fetch_base_images

  step "Plan: install the stock .31 base"
  say "  device:   Retroid Pocket 5, serial $SERIAL"
  say "  writes:   super (12 GiB) + boot chain + recovery, slot A, ONE fastboot process"
  say "  wipes:    userdata + metadata"
  if ((THEN_INSTALL)); then
    say "  then:     boots stock .31, waits for USB debugging, installs AshFall"
  else
    say "  then:     the device boots stock .31 and stops here"
  fi
  if ((!ASSUME_YES)); then
    if ((STOCK_ONLY)); then
      printf '\nType "restore" to wipe this device and install the stock .31 firmware: '
      read -r answer
      [[ $answer == restore ]] || die "aborted by the user"
    else
      printf '\nType "migrate" to wipe this device and install the .31 base: '
      read -r answer
      [[ $answer == migrate ]] || die "aborted by the user"
    fi
  fi
  if ((DRY_RUN)); then
    ok "dry run: firmware downloaded and verified, nothing was flashed"
    return 0
  fi

  flash_base adb
  ok "stock .31 base installed"

  if ((THEN_INSTALL)); then
    wait_for_debug
    local -a again=(--yes)
    if [[ -n $SERIAL ]]; then again+=(--serial "$SERIAL"); fi
    if ((!OC)); then again+=(--no-oc); fi
    step "Continuing with the AshFall install"
    exec "$0" "${again[@]}"
  fi

  say ""
  say "  The device is booting stock Android 13 now (2-5 minutes, setup wizard)."
  if ((STOCK_ONLY)); then
    say "  It stays on stock .31. Run ./install.sh when you want AshFall back"
    say "  (enable USB debugging first: Settings -> About -> tap Build number 7x"
    say "  -> Developer options -> USB debugging)."
  else
    say "  Then: enable USB debugging (Settings -> About -> tap Build number 7x ->"
    say "  Developer options -> USB debugging) and run ./install.sh again."
    say "  That second run installs AshFall and keeps working without another wipe."
  fi
  exit 0
}

# rescue_base: the same base restore, but starting from the bootloader and
# needing no adb, no Android and no fastbootd. This is the supported way out of
# a crash-dump loop, a wedged slot or a half-finished install.
rescue_base() {
  step "Rescue: reinstall the complete stock .31 base"
  say "  Works from the bootloader only (no Android, no fastbootd needed)."
  say "  Wipes userdata + metadata and pins slot A."
  say ""

  local -a boot=() other=()
  local dev mode try
  for try in 1 2 3; do
    boot=()
    other=()
    while read -r dev mode; do
      [[ -n $dev ]] || continue
      case $mode in
        fastboot) boot+=("$dev") ;;
        *) other+=("$dev") ;;
      esac
    done < <(fastboot devices 2>/dev/null)
    ((${#boot[@]})) && break
    # A reboot from fastbootd/Android can take a few seconds to enumerate.
    ((try < 3)) && sleep 5
  done

  if [[ -n $SERIAL ]]; then
    if ! printf '%s\n' "${boot[@]}" | grep -qx "$SERIAL"; then
      if printf '%s\n' "${other[@]}" | grep -qx "$SERIAL"; then
        die "device $SERIAL is in fastbootd, not the bootloader.
       Run:  fastboot reboot bootloader
       then: $0 --rescue"
      fi
      die "device $SERIAL is not in fastboot.
       Hold Power ~15 s, then Volume Down + Power until the fastboot screen
       appears, then re-run:  $0 --rescue${SERIAL:+ --serial $SERIAL}"
    fi
  else
    case ${#boot[@]} in
      1) SERIAL=${boot[0]} ;;
      0)
        if ((${#other[@]})); then
          die "the device is in fastbootd, not the bootloader.
       Run:  fastboot reboot bootloader
       then: $0 --rescue"
        fi
        die "no device in fastboot.
       Hold Power ~15 s, then Volume Down + Power until the fastboot screen
       appears, then re-run:  $0 --rescue"
        ;;
      *) die "several bootloader-mode devices (${boot[*]}); pick one with --serial" ;;
    esac
  fi
  ok "fastboot device $SERIAL (bootloader mode)"

  fetch_base_images

  if ((DRY_RUN)); then
    ok "dry run: firmware downloaded and verified, nothing was flashed"
    return 0
  fi
  if ((!ASSUME_YES)); then
    printf '\nType "rescue" to wipe this device and write the stock .31 base: '
    read -r answer
    [[ $answer == rescue ]] || die "aborted by the user"
  fi

  flash_base fastboot
  ok "stock .31 base restored"
  say ""
  say "  The device is rebooting to stock Android 13 (2-5 minutes, setup wizard)."
  say "  Then enable USB debugging and run ./install.sh to install AshFall."
  exit 0
}

# wait_for_debug: after a wipe the adb keys are gone, so a --then-install run
# has to wait for the user to finish setup and re-authorise this computer.
wait_for_debug() {
  local deadline frames=0
  deadline=$(( $(date +%s) + WAIT_DEBUG ))
  step "Waiting for USB debugging (up to $((WAIT_DEBUG / 60)) min)"
  say "  On the device:"
  say "    1. finish the Android setup wizard"
  say "    2. Settings -> About phone -> tap Build number 7x"
  say "    3. System -> Developer options -> USB debugging: on"
  say "    4. accept the 'Allow USB debugging' prompt for this computer"
  say ""
  while (( $(date +%s) < deadline )); do
    if adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1'; then
      ok "USB debugging is back (device $SERIAL)"
      return 0
    fi
    frames=$((frames + 1))
    if ((frames % 10 == 0)); then say "  still waiting... (${frames} checks)"; fi
    sleep 3
  done
  die "USB debugging did not come back within $((WAIT_DEBUG / 60)) min. The device is on stock .31; enable USB debugging and run ./install.sh when ready (do not re-run the restore - it would wipe again)."
}

# --- rescue: bootloader-only, no adb, no fastbootd ---------------------------
if ((RESCUE)); then
  rescue_base
  exit 0
fi

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


PLATFORM=$(adb_ shell getprop ro.board.platform 2>/dev/null | tr -d '\r' || true)
[[ $PLATFORM == kona ]] || die "this is not a Retroid Pocket 5 (ro.board.platform='${PLATFORM:-unknown}', expected 'kona'). Nothing was written."

# The stock vendor branch is the hard compatibility boundary: AshFall is an
# Android 17 GSI which needs the Android 13 / 5.15 vendor of the pre-release
# .31 firmware. The retail .34-.189 line ships an Android 11 vendor, a 4.19
# kernel and VINTF level 5, and Android 17 has no compatibility matrix for it.
# Flashing there would bootloop, so refuse before anything is downloaded.
VENDOR_SDK=$(adb_ shell getprop ro.vendor.build.version.sdk 2>/dev/null | tr -d '\r' || true)
VENDOR_SDK=${ASH_INSTALLER_TEST_VENDOR_SDK:-$VENDOR_SDK}
BASE_OK=0
if [[ $VENDOR_SDK == 33 ]]; then BASE_OK=1; fi
BATTERY=$(adb_ shell dumpsys battery 2>/dev/null | awk -F': ' '/level/{print $2; exit}' | tr -d '\r' || true)
if [[ ${BATTERY:-0} =~ ^[0-9]+$ ]] && ((BATTERY < 30)); then
  die "battery is ${BATTERY}%; charge to at least 30% before flashing"
fi
CUR_SLOT=$(adb_ shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r' || true)
if ((BASE_OK)); then
  ok "Retroid Pocket 5 (kona), Android 13 vendor (SDK 33), battery ${BATTERY:-unknown}%, slot ${CUR_SLOT:-unknown}, serial $SERIAL"
else
  ok "Retroid Pocket 5 (kona), retail firmware (vendor SDK ${VENDOR_SDK:-unknown}), battery ${BATTERY:-unknown}%, slot ${CUR_SLOT:-unknown}, serial $SERIAL"
  warn "the stock .31 base is required for AshFall; this device runs the retail firmware"
fi

if ((CHECK_ONLY)); then
  step "Preflight only"
  if ((STOCK_ONLY)); then
    say "mode:      restore the stock .31 firmware, slot A (wipes userdata + metadata)"
    say "download:  3.1 GB from the public Retroid package, pinned SHA-256"
    say "flash:     super (12 GiB) + boot chain in one fastboot process"
    if ((THEN_INSTALL)); then say "then:      wait for USB debugging and install AshFall $TAG"; fi
  else
    say "release:   $TAG"
    say "checksums: $SUM_FILE"
    say "would flash: $( ((BASE_OK)) || printf 'stock .31 base, then ' )system image$( ((OC)) && printf ' + GPU vendor_boot') + wipe userdata/metadata"
  fi
  ok "ready (nothing was downloaded or written)"
  exit 0
fi

# A stock restore is requested explicitly: ignore the base detection and go
# straight to the firmware flash (this is the "put it back" path).
if ((STOCK_ONLY)); then
  migrate_base
  exit 0
fi

if ((!BASE_OK || MIGRATE)); then
  if ((NO_MIGRATE)); then
    die "unsupported stock firmware: this device reports vendor SDK '${VENDOR_SDK:-unknown}', AshFall needs SDK 33 (the pre-release .31 base).
   The retail .34-.189 firmware has an Android 11 vendor (SDK 30, VNDK 30, 4.19 kernel) and cannot run this Android 17 system image.
   Nothing was written (--no-migrate). Re-run without --no-migrate to install the .31 base, or see README -> Base firmware."
  fi
  migrate_base
  exit 0
fi


# --- download + verify -------------------------------------------------------
step "Fetching AshFall $TAG"
mkdir -p "$DL"
if ((FRESH)); then
  rm -f "$DL/system.img.xz" "$DL/system.img" "$DL/vendor_boot.img" "$DL/vbmeta.img"
fi

ASSETS=(system.img.xz vbmeta.img)
if ((OC)); then ASSETS+=(vendor_boot.img); fi
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
if ((OC)); then verify_one vendor_boot.img; fi
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
say "  data:         ERASED (mandatory: userdata + metadata)"
say ""
say "  The device reboots twice and runs two flashes. Do not unplug it, do not touch buttons."
if ((!ASSUME_YES)); then
  warn "this ERASES all data on the device: userdata + metadata"
  printf '\nContinue? [y/N] '
  read -r answer
  case $answer in y|Y|yes) : ;; *) die "aborted by the user" ;; esac
fi
if ((DRY_RUN)); then
  ok "dry run: nothing was written to the device"
  exit 0
fi

# --- phase 1: system image (fastbootd) --------------------------------------
MARKER="$DL/.phase1-done"
if ((RESUME)); then
  [[ -f $MARKER ]] || die "--resume: no completed phase 1 recorded in $DL. Run a normal install."
  ok "phase 1 already flashed ($MARKER); resuming at the bootloader"
else
step "Phase 1/2: system image (fastbootd)"
adb_ reboot fastboot
MODE=""
for ((i = 0; i < 120; i++)); do
  MODE=$(fb_getvar is-userspace)
  if [[ $MODE == yes ]]; then break; fi
  sleep 1
done
[[ $MODE == yes ]] ||
  die "the device did not reach fastbootd.
       If the screen went black and the device disappeared from lsusb, it
       panicked instead of booting fastbootd. Power-cycle it (hold Power 15 s),
       then Volume Down + Power for the bootloader, and run:
         $0 --rescue
       That rewrites the complete stock .31 base (including recovery) from the
       bootloader and does not need Android or fastbootd.
       Otherwise re-plug the USB cable and re-run."
SLOT=$(fb_getvar current-slot)
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
: > "$MARKER"
fi

# --- phase 2: bootloader (vendor_boot + vbmeta + optional wipe) -------------
# One fastboot process for the whole bootloader-side batch: the RP5 ABL wedges
# when a new fastboot opens between transfers (issue #54).
step "Phase 2/2: bootloader (vbmeta$( ((OC)) && echo ', vendor_boot')$([[ $WIPE == 1 ]] && echo ', wipe'))"
fb_ reboot bootloader || warn "fastboot reboot bootloader failed; trying adb"
if ! wait_for_bootloader; then
  # Fallback when fastbootd cannot jump to the bootloader: let Android come up
  # (the old system is still bootable) and reboot from there.
  warn "bootloader not reached from fastbootd; rebooting to Android and retrying"
  adb_ wait-for-device >/dev/null 2>&1 || true
  for ((i = 0; i < 120; i++)); do
    adb_ shell getprop sys.boot_completed 2>/dev/null | grep -q '^1' && break
    sleep 2
  done
  adb_ reboot bootloader
  wait_for_bootloader ||
    die "the device did not reach the bootloader.
       Hold Power ~15 s, then Volume Down + Power for the bootloader, then run:
         $0 --resume
       (phase 1 is already on the device; --resume skips it)"
fi
# No product/unlocked getvars here: they were checked over adb in the preflight,
# and every extra getvar is another session on a fragile service (#54).
guard_single_fastboot
fb_probe
if [[ $FB_UNLOCKED == no ]]; then
  die "the bootloader is locked; unlock it first and re-run"
fi
ok "bootloader ready (product=${FB_PRODUCT:-unknown}, slots=${FB_SLOTS:-unknown})"

BATCH=(--disable-verity --disable-verification flash vbmeta "$DL/vbmeta.img")
if ((OC)); then
  BATCH+=(flash vendor_boot "$DL/vendor_boot.img")
fi
if ((WIPE)); then
  BATCH+=(erase userdata erase metadata)
fi
BATCH+=(reboot)
FB_TIMEOUT=900
say "one fastboot process, do not unplug; a stall is detected after ${FB_TIMEOUT}s"
if ! fb_batch "${BATCH[@]}"; then
  die "the bootloader phase did not finish (wedged ABL or USB drop).
       Do NOT unplug.
       1. Hold Power ~15 s, then Volume Down + Power to return to the bootloader.
       2. Re-run:  $0 --resume${SERIAL:+ --serial $SERIAL}
          (phase 1 is already flashed; only the bootloader phase runs)
       If it wedges again, run the full base rescue instead:  $0 --rescue"
fi
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
