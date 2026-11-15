# Manual install (raw commands)

Use this when `install.sh` cannot run (for example natively on Windows) or when
you want to see exactly what it does. The end state is identical: the same
three artifacts, the same two flashes, the same one-process rule for the
bootloader.

Download these three files from
`https://github.com/ashfall-rom/ashfall-install/releases/tag/v0.1.0`
into the same folder (private repo: you need access):

- `system.img.xz` → unpack with 7-Zip (Windows) or `xz -dc system.img.xz > system.img`
- `vendor_boot.img` (skip it if you do not want the GPU overclock)
- `vbmeta.img`

Verify the hashes against `releases/v0.1.0/SHA256SUMS` (Windows:
`certutil -hashfile system.img.xz SHA256`).

## 0. Preflight

```sh
adb devices                      # exactly one device, state "device"
adb shell getprop ro.board.platform   # must print: kona
adb shell dumpsys battery | grep level  # charge above 30 %
```

## 1. System image (fastbootd)

```sh
adb reboot fastboot
fastboot devices                 # the device is in fastbootd
fastboot getvar is-userspace     # "yes"
fastboot getvar current-slot     # "a" or "b" -> $SLOT below
fastboot flash system_$SLOT system.img
```

This takes a few minutes. If it fails with no space left:

```sh
fastboot delete-logical-partition product_$SLOT
fastboot delete-logical-partition system_ext_$SLOT
```

## 2. Bootloader (vendor_boot + vbmeta), ONE process

The RP5 bootloader wedges when a second fastboot process opens between
transfers, so this is a single command line. Do not add `getvar`s between the
writes.

```sh
fastboot reboot bootloader
fastboot devices                 # bootloader, not fastbootd
fastboot getvar product          # must print: kona
fastboot getvar unlocked         # must print: yes
```

Then, one process:

```sh
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img \
         flash vendor_boot vendor_boot.img \
         reboot
```

With `--no-oc` (stock GPU support) drop `flash vendor_boot vendor_boot.img`.
With a data wipe add `erase userdata erase metadata` before `reboot`.

## 3. First boot

Two to five minutes. Then **Settings → AshFall settings**.

## Windows notes

`adb`/`fastboot` work natively on Windows (platform-tools). 7-Zip unpacks
`.xz`. The command syntax above is identical in PowerShell; use `.\fastboot.exe`
if the folder is not on `PATH`, and replace the line continuations with one
line. WSL works with `./install.sh` as-is (USB must be attached to WSL — with
`usbipd` on Windows 11, or just use the native commands).

## Undo

```sh
# stock vendor_boot back (needs the stock image for your slot; see recovery.md)
fastboot --disable-verity --disable-verification flash vbmeta stock-vbmeta.img flash vendor_boot stock-vendor_boot.img reboot
```

A full return to stock firmware is described in `docs/recovery.md`.
