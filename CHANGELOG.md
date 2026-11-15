# Changelog

## Unreleased

- **Verified end-to-end on hardware (2026-11-15):** `--rescue` wrote the
  complete `.31` base (12 GiB `super`, chunked at 512 MiB) and a normal
  `./install.sh` then flashed the AshFall system image + `vendor_boot`. The RP5
  boots AshFall on slot A with `ashfall-hwd` publishing status.
- **Slow writes are normal here:** after the 12 GiB `super` write, even a 96 MiB
  `Writing 'boot_a'` can take several minutes on this UFS (observed: ~10 min for
  that step). The base batch allows 60 minutes; do not unplug and do not start
  another fastboot.
- **No silent exits.** `set -euo pipefail` plus a guard that ran `pgrep -x
  fastboot` (which exits 1 when nothing matches) made `--rescue` exit right
  after the confirmation with no message. `fastboot_clients()` now never
  returns non-zero for "no client found", and an `ERR` trap prints the failing
  line and command for any unhandled failure.
- **No more getvar gate; one client only.** A Qualcomm ABL with a healthy
  variable service can still answer erratically once a *second* fastboot client
  is reading the same replies (mixing `GetVar Variable Not found` with
  `unknown command`, answers changing between sessions). The installer now
  refuses to run while any other fastboot process exists, and probes
  `product`/`slot-count`/`unlocked` in ONE process for information only. A
  missing variable is no longer treated as a fault, and the false "only a full
  power cycle clears this" advice is gone.
- **`super` is flashed with `-S 512M`.** `File is too large to download` is the
  fastboot client's own 4 GiB download cap, not a bootloader fault: without a
  chunk size the raw 12 GiB image is sent as one download. `-S 512M` caps each
  download below this ABL's buffer and the client limit.
- **`vbmeta_system` is written as `vbmeta_system_a`**, its real GPT name.
- **Bootloader capability probe before any big write.** The RP5 ABL's variable
  service wedges and then returns nothing for `partition-size:super` /
  `max-download-size`; fastboot turns that into `Sending 'super' (0 KB) FAILED
  (File is too large to download)` after doing nothing. The installer now probes
  both and stops in seconds with the power-cycle instruction instead of
  starting a doomed 12 GiB batch. Applied to `--rescue` and to phase 2.
- **`--resume`**: after phase 1 (the 2.2 GB system flash) the installer records
  a marker; if the bootloader phase fails or stalls, `--resume` skips phase 1
  and reruns only the bootloader batch.
- **No fastboot polling, and a watchdog**: the bootloader wait is a fixed pause
  plus at most two checks instead of a per-second `fastboot devices` loop (each
  of those is a new session, and new sessions are what wedge this ABL mid-
  transfer). Every batch now runs under a watchdog: a stall fails with
  instructions instead of hanging forever (600-900 s for the bootloader phase,
  3600 s for the 12 GiB base flash).
- **`--rescue`**: bootloader-only restore of the complete stock `.31` base
  (`super`, boot chain, `vbmeta`, `vbmeta_system`, `recovery_a/b`), slot A
  pinned, no adb/fastbootd needed. The supported way out of a crash-dump loop
  or a half-finished install.
- **Complete base set**: the base install now includes `recovery_a/b`. The ROM
  does not use recovery, but `adb reboot fastboot` boots it, and a recovery
  that does not match the stock vbmeta panics — the exact failure behind the
  2026-11-15 black screens.
- **`restore-stock.sh`**: put the device back on the stock `.31` firmware
  (pinned download, one fastboot process, wipes data). `--then-install` waits
  for USB debugging to come back and installs AshFall in the same run, so a
  clean reinstall is one command.
- **`install.sh --stock [--then-install] [--wait-debug N]`**: the same path,
  reachable from the installer.
- The installer now refuses retail firmware with a clear message instead of
  bootlooping on it, and the stock-firmware migration is part of `install.sh`
  (retail `.189` -> `.31` base -> AshFall).
- Fixed several `set -e` traps that could abort the firmware path instead of
  retrying (`fb_getvar`, kick/asset one-liners).

## v0.1.0 - 2026-11-15

First installable AshFall release for the Retroid Pocket 5.

- ROM build `phase5-v3-1` (ROM commit `eef852a`): LineageOS 24 GSI, Android 17.
- **AshFall settings** (`org.ashfall.parts`): Fan, Lighting, Controller pages.
  The Fan page has a live 60 s graph of temperature, fan output and RPM, plus
  **fan speed limits** (`persist.ashfall.fan.min_pct` / `max_pct`, defaults
  5 % / 100 %): below the minimum the fan stops completely, above the maximum it
  stays at the maximum. The daemon enforces both; thermal protection is exempt.
- **GPU**: `vendor_boot` with the Adreno 650 power table (1000/940/850/765 MHz
  available; the cap stays at stock 670 MHz until selected in AshFall settings).
- Boot verification disabled (`vbmeta` flags 3) so the GSI boots on the stock
  vendor.
- Installer: one command, checksum-pinned, one bootloader fastboot process
  (issue #54), `--check` / `--dry-run` / `--no-oc` / `--wipe` / `--release`.
