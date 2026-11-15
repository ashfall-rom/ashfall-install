# How it works

The installer is intentionally small: it downloads three files that were built
and tested elsewhere, verifies them, and writes them with the fewest fastboot
sessions the RP5 bootloader tolerates.

## The artifacts

| file | what it is | built by |
|---|---|---|
| `system.img.xz` | the AshFall GSI system image (ext4, ~2.2 GiB unpacked), containing LineageOS 24, the AshFall settings app and `ashfall-hwd` | `scripts/build.sh` in [ashfall-rom/ashfall](https://github.com/ashfall-rom/ashfall) |
| `vendor_boot.img` | the stock vendor_boot with the Adreno 650 power-level tables replaced (1000/940/850/765 MHz available) | `scripts/gpu/build-vendor-boot.sh`, published in [ashfall-rom/rp5-vendor_boot](https://github.com/ashfall-rom/rp5-vendor_boot) |
| `vbmeta.img` | the stock vbmeta descriptor; the installer flashes it with verity and verification disabled, which a GSI needs | stock firmware |

The kernel is **not** replaced: AshFall boots the stock 5.15 GKI kernel and the
stock vendor modules. The GPU overclock is a device-tree data change, and the
GPU cap stays at stock 670 MHz until you select a higher step in
**AshFall settings → Power**.

## Why this order

1. **System first, in fastbootd.** The system image lives in `super` (a logical
   partition), which the Android userspace fastboot writes. This is also the
   only place `current-slot` is easy to query.
2. **Then bootloader writes, in one process.** `vendor_boot` and `vbmeta` are
   physical partitions that only the bootloader's fastboot can write. The RP5
   bootloader (ABL) wedges if a new fastboot process opens between transfers,
   so the installer passes all of it as one command line: `flash vbmeta`,
   `flash vendor_boot`, optional `erase`, `reboot`.
3. **Then wait.** The first boot after `vbmeta` changes takes minutes.

The bootloader cannot jump to fastbootd on this device (`fastboot reboot
fastboot` is rejected), so the installer starts from Android and only uses
`fastboot reboot bootloader` in the other direction, with a fallback through
Android if that ever fails.

## Why checksums are pinned in the repo

The installer never trusts the network: `releases/<tag>/SHA256SUMS` is committed
here, and every downloaded file — including the *unpacked* `system.img` — is
checked against it before fastboot sees it. A release is immutable; a new build
gets a new tag, and the repo gains a new `releases/<tag>/` directory.

## What is out of scope

- Building: use the ROM repository (`scripts/build.sh`).
- The GPU DTB pipeline and its measurements: `docs/rp5/gpu.md` there.
- A full stock-firmware restore: `docs/recovery.md` points at the ROM repo's
  procedure; this installer only handles the AshFall install and the stock
  vendor_boot rollback.
