# Changelog

## Unreleased

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
