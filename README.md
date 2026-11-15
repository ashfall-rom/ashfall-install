# AshFall for the Retroid Pocket 5

One command installs AshFall on an RP5: the AshFall system image (LineageOS 24
GSI), the **AshFall settings** app (fan, lighting, controller, power) and,
unless you pass `--no-oc`, the GPU-capable `vendor_boot` (Adreno 650 table with
850/940/1000 MHz available; the GPU cap itself stays stock until you opt in).

```
git clone https://github.com/ashfall-rom/ashfall-install.git
cd ashfall-install
./install.sh
```

The installer checks your device, downloads the pinned release, **verifies every
checksum**, asks once, flashes, reboots twice and waits until AshFall boots.
It never flashes anything outside `system_<slot>`, `vendor_boot` and `vbmeta`,
and it keeps your data unless you pass `--wipe`.

> **Alpha, and a private release repo.** The release contains the stock
> Retroid/Qualcomm `vendor_boot` payload. Do not redistribute the release
> assets. The installer needs `gh` logged in with access to this repo.

## What you need

| | |
|---|---|
| Device | Retroid Pocket 5 (SM8250 "kona"), bootloader **unlocked** |
| Base firmware | the pre-release stock **`.31`** vendor (Android 13, 5.15 GKI). Retail `.34`–`.189` units ship an Android 11 vendor + 4.19 kernel and are **not** supported; the installer refuses them (vendor SDK check) |
| Cable | USB-C data cable (not charge-only) |
| Computer | Linux, macOS or WSL with `adb`, `fastboot`, `gh`, `xz` |
| Disk | ~5 GB free for the download + unpacked image |
| Device battery | at least 30 % |
| Device setting | **USB debugging** on: Settings → About → tap *Build number* seven times, then Developer options → USB debugging |

Install the tools in one line:

```bash
# macOS (Homebrew)
brew install android-platform-tools gh xz
# Debian/Ubuntu
sudo apt install adb fastboot gh xz-utils
# Arch
sudo pacman -S android-tools github-cli xz
```

Then `gh auth login` once (the release repo is private).

## Unlock the bootloader (once, erases data)

1. On the RP5: **Settings → About** → tap **Build number** seven times.
2. **Settings → System → Developer options**: enable **USB debugging** and
   **OEM unlocking**.
3. Connect USB, accept the debugging prompt, then on the computer:

   ```bash
   adb reboot bootloader
   fastboot flashing unlock
   ```

   Confirm with the volume keys + power on the device. It wipes data.
4. After setup, enable **USB debugging** again (the unlock wipes the setting).

## Install

```bash
./install.sh              # install the pinned version
./install.sh --check      # look, do not touch: device, battery, release
./install.sh --dry-run    # download + verify, print the plan, write nothing
```

Useful options:

| flag | effect |
|---|---|
| `--no-oc` | keep the stock `vendor_boot` (no GPU overclock steps at all) |
| `--wipe` | erase userdata + metadata (clean install, needed when switching from another ROM) |
| `--release TAG` | install another version pinned in `releases/` (rollback) |
| `--serial X` | pick a device when several are attached |
| `--fresh-download` | ignore files already in `ashfall-download/` |
| `--yes` | no confirmation prompt |

The first boot takes 2–5 minutes. When it is up: **Settings → AshFall settings**.

## What gets written

| partition | content | why |
|---|---|---|
| `system_<slot>` | AshFall system image (GSI, ext4) | the ROM |
| `vendor_boot` | stock image + the Adreno 650 power table | makes 850/940/1000 MHz selectable; `--no-oc` skips it |
| `vbmeta` | stock vbmeta, flashed with verity + verification disabled | required to boot a GSI |

Nothing else is touched — not `boot`, `vendor`, `odm`, `product`,
`system_ext`, `userdata` (unless `--wipe`), and never any partition on the
NEVER-flash list. Both `vendor_boot` and `vbmeta` are written in **one fastboot
process**, because the RP5 bootloader wedges when a second one opens between
transfers.

## Back to stock

The installer can put the device back on the stock `.31` firmware (3.1 GB
download, ~13 GB temp disk, `super` + boot chain in one fastboot process,
**erases data**):

```bash
./restore-stock.sh                 # restore stock .31 and stay there
./restore-stock.sh --then-install  # restore, then wait until you re-enable
                                   # USB debugging and install AshFall again
```

With `--then-install` the script stops after the stock flash, prints the
Developer-options steps, polls until adb is authorised again and then continues
with the normal install in the same run — so a "clean reinstall" is one command.
Without it the device simply stays on stock `.31`; run `./install.sh` when you
want AshFall back.

If the device cannot boot Android or fastbootd at all (crash-dump mode
`05c6:900e`, wedged slot, half-finished install), use the bootloader-only
rescue:

```bash
# device in the bootloader (Power 15 s, then Volume Down + Power)
./install.sh --rescue
```

It rewrites the **complete** stock `.31` base — `super`, boot chain, `vbmeta`,
`vbmeta_system` and `recovery` — pins slot A, wipes data, and needs no adb.
This is also the supported fix if a previous installer ever left you with a
black screen after the logo.

Both are the same code path the installer uses to migrate a retail `.189`
device, so there is one implementation, one set of pinned hashes.

## First boot, updates, recovery

- **Bootloop or stuck on the animation**: usually stale `/data` from another
  ROM → `./install.sh --wipe`.
- **"no space left" during the system flash**: the installer prints the two
  `delete-logical-partition` commands to free the stock `product_*` /
  `system_ext_*` and re-run.
- **Back to stock**: `./restore-stock.sh` (full stock `.31`, wipes data) or
  `./restore-stock.sh --then-install` (restore + reinstall AshFall). Partial
  recovery (stock `vendor_boot` only, keeping the current install) is in
  `docs/recovery.md`.
- **Updates**: `git pull` (new `VERSION` + `releases/<tag>/SHA256SUMS`), then
  `./install.sh`. Data is kept.

## Versions

| tag | ROM build | notes |
|---|---|---|
| `v0.1.0` | `phase5-v3-1` (`eef852a`) | first public install: fan graph + fan output limits, GPU OC vendor_boot, AshFall settings v3 |

`docs/manual-install.md` has the same steps as raw commands (also the Windows
path without WSL). `docs/how-it-works.md` explains what each artifact is and
why. This repository is Apache-2.0; the firmware inside the release assets is
not.

## Releasing a new version

The ROM repository builds, this repository ships. For a new ROM build:

1. Build it there (`scripts/build.sh`), then compress the artifact on the build
   host: `xz -T12 -6 -c system.img > system.img.xz` (~880 MB).
2. Create a new tag here with the assets `system.img.xz`, `vendor_boot.img`
   (from the pinned `ashfall-rom/rp5-vendor_boot` release), `vbmeta.img`
   (stock) and `SHA256SUMS`.
3. Add `releases/<tag>/SHA256SUMS` (compressed **and** unpacked `system.img`
   hashes) and bump `VERSION`, then commit.
4. `./install.sh --release <tag> --dry-run` against the new tag before
   announcing it.

