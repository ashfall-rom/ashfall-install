# Recovery

Work from least destructive to most. Stop as soon as the device boots.

## The device does not boot after the install

1. **Wait five minutes.** The first boot after a flash is slow, especially
   right after `--wipe`.
2. **Connect USB and check adb:**

   ```sh
   adb devices
   adb shell getprop sys.boot_completed
   ```

   If adb answers but boot never completes, the data partition is probably from
   another ROM: re-run `./install.sh --wipe`.
3. **Stuck on the boot animation with adb working**: read the reason:

   ```sh
   adb logcat -d | grep -iE "fatal|avb|dm-verity|mount" | tail -40
   ```

4. **No adb, boot loop**: enter the bootloader manually — hold **Power 15 s**
   to power off, then **Power + Volume Down** — and re-flash the stock
   `vendor_boot` (below). The GSI system image can also be re-flashed with
   `./install.sh` from fastbootd.

## Back to the stock vendor_boot (keeps the system image)

You need the stock `vendor_boot` for the device (`lun4_vendor_boot_a.bin` from
the stock firmware package) and the stock vbmeta:

```sh
adb reboot bootloader
fastboot devices
fastboot --disable-verity --disable-verification flash vbmeta stock-vbmeta.img \
         flash vendor_boot stock-vendor_boot.img \
         reboot
```

One process again — never two `fastboot` invocations for these writes.

## Back to the stock ROM from the installer

```bash
./restore-stock.sh                 # stock .31, wipe, stay on stock
./restore-stock.sh --then-install  # stock .31, then reinstall AshFall
```

This is the supported route: it uses the pinned `.31` package and the single
fastboot batch. Use the manual steps below only when the installer cannot run.

## Back to the stock ROM completely

That is the stock-firmware restore path, not something this repository
automates: the RP5 bootloader only exposes slot A images in the stock package,
and the restore needs the vendor/super images from `Android13_RP5_V1.0.0.31`.
The ROM repository's `scripts/device/restore-stock.sh` and
`docs/reference/rp5-recovery-guide.md` §8 describe it (one fastboot session,
never per-partition). Do not improvise this step; a wrong partition write on
this bootloader is a hard brick risk.

## "no space left" while flashing the system image

The dynamic partition group is 6 GiB. Free the stock partitions the GSI does
not use, then re-run:

```sh
fastboot delete-logical-partition product_$SLOT
fastboot delete-logical-partition system_ext_$SLOT
```

Everything else (`vendor`, `odm`, `system_dlkm`, `vendor_dlkm`) is untouched.

## The bootloader will not accept commands

- "Sending 'vendor_boot'" hangs: the padded 96 MiB image was used. Only the
  content-only image from the release (12,931,072 B) is valid — the installer
  checks this.
- A burst of `fastboot` processes leaves the ABL unresponsive: hold **Power
  15 s**, then **Power + Volume Down**, and retry with a single command.
- `fastboot reboot fastboot` is rejected by this bootloader by design. Reach
  fastbootd with `adb reboot fastboot` from Android (or via recovery:
  `adb reboot recovery`, then `adb reboot fastboot`).

## Data and warranty

- `--wipe` erases userdata and metadata. Back up first.
- Unlocking the bootloader wipes data and usually voids the warranty.
- The release assets include proprietary Retroid/Qualcomm files
  (`vendor_boot`). Do not redistribute them.
