# Changelog

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
