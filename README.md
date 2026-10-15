# Restore an Apple silicon Mac from Linux (DFU + idevicerestore)

**English** | [Español](README.es.md)

A guide and scripts to fix the macOS error **"Failed to personalize the software update"** when it is caused by a missing system recovery partition (**error 1256: `Failed to find SFR recovery volume`**). The fix is to restore the Mac in **DFU mode** from a **Linux** PC using [idevicerestore](https://github.com/libimobiledevice/idevicerestore), **with no second Mac required**.

> [!WARNING]
> **Restoring with `-e` erases everything on the Mac.** Make a backup (Time Machine or similar) first if there is any data you want to keep.
> This method is **not official and not supported by Apple**. This project is not affiliated with Apple or with libimobiledevice. Use it at your own risk.

> [!NOTE]
> The scripts print their messages in Spanish. The commands and steps below work the same regardless of language.

---

## Contents

- [The problem](#the-problem)
- [Diagnosis](#diagnosis)
- [Possible fixes](#possible-fixes)
- [Requirements](#requirements)
- [Step by step](#step-by-step)
- [Troubleshooting](#troubleshooting)
- [Tested on](#tested-on)
- [Credits](#credits)
- [License](#license)

---

## The problem

When you try to update macOS from *System Settings → Software Update* (or with `softwareupdate`), you get:

> **Failed to personalize the software update. Please try again.**
> An error occurred while downloading the selected updates. Please check your internet connection and try again.

The message points to an internet problem, but **that is not the cause**. Switching networks, restarting, using Safe Mode or updating from Terminal does not help.

The real error is in `/var/log/install.log`:

```
Failed to perform PreflightPersonalize operation: [MobileSoftwareUpdateErrorDomain(MSU):1256]
... SUMacControllerErrorIndicationsMask=0 ...
Error Domain=MobileSoftwareUpdateErrorDomain Code=1256 "Failed to find SFR recovery volume"
```

### The cause

On an Apple silicon Mac, the last partition of the internal disk should be **`Apple_APFS_Recovery`**, which holds System Recovery. According to the [Asahi Linux documentation](https://asahilinux.org/docs/sw/partitioning-cheatsheet/), **if that partition is missing, macOS upgrades stop working**.

This is what the affected disk looked like (`diskutil list`). It has only two partitions:

```
/dev/disk0 (internal, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *1.0 TB     disk0
   1:             Apple_APFS_ISC Container disk1         524.3 MB   disk0s1
   2:                 Apple_APFS Container disk2         1.0 TB     disk0s2
```

A healthy disk also has a third partition of roughly 5 GB:

```
   3:        Apple_APFS_Recovery Container ...            5.3 GB     disk0s3
```

---

## Diagnosis

Before restoring, **confirm that this is your problem**. The script [`scripts/diagnostico-actualizacion.sh`](scripts/diagnostico-actualizacion.sh) **only reads information and changes nothing**. It checks:

- Clock, `/etc/hosts`, proxy, VPN and network filters, firewall.
- Connectivity to Apple's update servers.
- **Whether the `Apple_APFS_Recovery` partition exists.**
- The boot identity folders (`iSCPreboot`).
- The last personalization error in `install.log`, with an interpretation.

On the Mac, open Terminal and run:

```bash
sudo bash ~/Downloads/diagnostico-actualizacion.sh > ~/Desktop/diagnostico.txt 2>&1
```

Open `diagnostico.txt` on the Desktop. **This method applies if the result shows error 1256 and a missing `Apple_APFS_Recovery`.** If the error is different, for example `kAMAuthInstallErrorServerNotReachable`, the problem really is the network and this guide does not apply.

---

## Possible fixes

| Option | Erases data? | Difficulty | Notes |
|---|---|---|---|
| **Apple Authorized Service Provider** | Usually yes | Low | Official method, using Apple's tools. |
| **Recreate the partition by hand + revive** | No (in theory) | High | [Guide by Arbifox on r/AsahiLinux](https://www.reddit.com/r/AsahiLinux/comments/1fmnzm5/guide_how_to_fix_failed_to_find_sfr_recovery/). Requires disabling SIP, `gdisk` and exact partition math. |
| **DFU restore from Linux** (this guide) | **Yes, everything** | Medium | Works without a second Mac. |

---

## Requirements

- **An Apple silicon Mac.** Tested on a MacBook Air (M1, 2020).
- **A Linux PC.** Tested on Linux Mint 22.3 Cinnamon. The setup script was also validated on Ubuntu 24.04, the base of the whole Linux Mint 22 series. It uses `apt`, so it should work on other Ubuntu 24.04–based distributions, but those were not tested.
- **A USB-C cable that carries data.** Apple requires a USB-C to USB-C cable that supports data and charging, and [Thunderbolt 3 cables are not supported](https://support.apple.com/en-us/108900). Charge-only cables will not work.
- **Free space on the Linux PC.** macOS firmware files are about 20–27 GB. Keep at least 40 GB free.
- **An internet connection** on the Linux PC.
- **The Apple Account password** for the Mac, in case Activation Lock asks for it after the restore.
- **The Mac plugged into its charger** for the whole process.

---

## Step by step

### 1. Prepare Linux (build idevicerestore)

The script [`scripts/preparar-mint-idevicerestore.sh`](scripts/preparar-mint-idevicerestore.sh) does the following:

1. Installs the build tools with `apt`.
2. Downloads from the **official libimobiledevice repositories on GitHub** and builds, in this order: `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `usbmuxd` and `idevicerestore`. Everything is installed under `/usr/local`.
3. Creates the `usbmux` system user, which the `usbmuxd` service needs in order to start, and reloads `udev` and `systemd`.

```bash
cd ~/Downloads
bash preparar-mint-idevicerestore.sh
```

It asks for your password and takes several minutes. When it finishes, **reboot the PC** and check:

```bash
idevicerestore --version     # → idevicerestore 1.0.0-git-... (libirecovery ..., libtatsu ...)
which irecovery usbmuxd      # → paths under /usr/local/...
id usbmux                    # → uid=...(usbmux)
```

### 2. Download and verify the firmware (IPSW)

Create a working folder:

```bash
mkdir -p "$(xdg-user-dir DESKTOP)/restaurar-mac" && cd "$(xdg-user-dir DESKTOP)/restaurar-mac"
```

Look up your model on [ipsw.me](https://ipsw.me) to see the signed macOS versions, their official links (`updates.cdn-apple.com`) and their SHA-256 checksums. You can also query its API, for example for the MacBook Air M1: `https://api.ipsw.me/v4/device/MacBookAir10,1?type=ipsw`.

Example with **macOS 26.6.2 (25G83)** for the MacBook Air M1:

```bash
wget -c https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw
sha256sum UniversalMac_26.6.2_25G83_Restore.ipsw
# Must be exactly:
# 885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95
```

- `-c` resumes the download if it gets interrupted.
- **If the SHA-256 does not match, stop.** Delete the file and download it again.

> Alternative: `idevicerestore -l` lists the signed versions and downloads the one you choose. Downloading manually has two advantages: you can verify the file, and the Mac does not have to wait in DFU mode during the download.

### 3. Connect the two machines

1. **Shut down the Mac.**
2. Connect the cable to the Mac's **DFU port**. According to [Apple (120694)](https://support.apple.com/en-us/120694):
   - **MacBook Air models introduced in 2025 or later:** the **rightmost** USB-C port when you face the left side of the Mac.
   - **Other laptop models** (including the MacBook Air M1): the **leftmost** USB-C port when you face the left side, i.e. the one closest to the hinge.
   - Mac mini, Mac Studio and others: see Apple's article.
3. Plug the other end **directly** into the Linux PC, without a hub. A rear port is best.
4. Plug the Mac's charger into its other port.

### 4. Put the Mac into DFU mode (Apple silicon laptops)

Steps from [Apple's guide](https://support.apple.com/guide/apple-configurator-mac/revive-or-restore-a-mac-with-apple-silicon-apdd5f3c75ad/mac):

1. Press and **release** the power button (Touch ID).
2. Press the power button again and, **while holding it**, hold **left Control + left Option + right Shift** at the same time for about **10 seconds**.
3. Release the three keys, but **keep holding the power button**.
4. The Mac's screen must stay **black**. If the Apple logo appears, it booted normally: shut it down and try again.

**To know when to let go**, run this on Linux and keep holding the button until the DFU device shows up:

```bash
sudo dmesg -wH
```

```
usb 1-12: New USB device found, idVendor=05ac, idProduct=1227
usb 1-12: Product: Apple Mobile Device (DFU Mode)
usb 1-12: Manufacturer: Apple Inc.
```

### 5. Verify detection

```bash
sudo irecovery -q
```

Expected output (MacBook Air M1; identifiers omitted):

```
CPID: 0x8103
BDID: 0x26
ECID: 0x................
MODE: DFU
PRODUCT: MacBookAir10,1
MODEL: j313ap
NAME: MacBook Air (M1, 2020)
```

What matters is **`MODE: DFU`** and a `NAME` that matches your Mac.

### 6. Restore

```bash
sudo idevicerestore -e --logfile=restauracion.log UniversalMac_26.6.2_25G83_Restore.ipsw
```

- `-e` performs a full restore: **it erases everything** and installs a clean macOS.
- If it asks for confirmation, type what the screen tells you to.
- The Mac shows the Apple logo and a progress bar, and may restart several times.
- **Do not disconnect or turn off either machine** until the terminal says it has finished.

### 7. After the restore

1. Set up the Mac with Setup Assistant and sign in with your Apple Account if asked.
2. If you have a backup, use **Migration Assistant** to bring your data back.
3. Confirm that the recovery partition now exists:
   ```bash
   diskutil list | grep Apple_APFS_Recovery
   ```
4. Try *Software Update*.

When you are done, you can delete the working folder on Linux. The files are owned by root, which is why `sudo` is needed:

```bash
sudo rm -r "$(xdg-user-dir DESKTOP)/restaurar-mac"
```

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `irecovery -q` → `ERROR: Unable to connect to device` | The Mac is not in DFU mode yet | Watch `sudo dmesg -wH` while doing the key sequence. Run `irecovery` only after `DFU Mode` appears. |
| `dmesg` shows no Apple device at all | Charge-only cable, wrong Mac port or a USB hub | Use a data cable, the correct DFU port and a port directly on the PC. |
| `dmesg` shows `Recovery Mode` instead of `DFU Mode` | It entered Recovery, not DFU | Repeat the sequence, paying attention to the timing. |
| The `usbmuxd` service does not start | The `usbmux` user is missing | Run the setup script again; it creates the user. |
| `ucsi_handle_connector_change ... hogged CPU` messages in `dmesg` | Noise from the PC's USB-C controller | Harmless, ignore them. |
| The SHA-256 does not match | Incomplete or corrupted download | Delete the `.ipsw` and download it again. |

If `idevicerestore` fails, **do not retry blindly**. Check `restauracion.log` first. Apple silicon Macs cannot be permanently bricked ([Asahi Linux](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)): you can always enter DFU mode again and retry.

---

## Tested on

| | |
|---|---|
| **Mac** | MacBook Air (M1, 2020), `MacBookAir10,1`, `j313ap` |
| **macOS before** | 26.5.1 (25F80), with error 1256 and no `Apple_APFS_Recovery` |
| **macOS restored** | 26.6.2 (25G83) |
| **Linux PC** | Linux Mint 22.3 "Zena" Cinnamon (based on Ubuntu 24.04 LTS) |
| **idevicerestore** | `1.0.0-git-4b3e847` (libirecovery 1.3.1, libtatsu 1.0.5) |
| **Date** | October 15, 2026 |

The setup script downloads the latest version of each repository. If something changes in the future, the tested idevicerestore commit is `4b3e847`.

---

## Credits

This project **does not include or modify** any third-party code. The setup script downloads and builds the original software from its official repositories. All the technical credit for the restore itself goes to its authors.

### idevicerestore and libimobiledevice

- **[idevicerestore](https://github.com/libimobiledevice/idevicerestore)**, by **Joshua Hill**, **Martin Szulecki** and **Nikias Bassen** (the [libimobiledevice](https://libimobiledevice.org) project). Licensed under **LGPL-3.0**.
- **[libirecovery](https://github.com/libimobiledevice/libirecovery)**, **[libtatsu](https://github.com/libimobiledevice/libtatsu)**, **[libimobiledevice](https://github.com/libimobiledevice/libimobiledevice)**, **[libplist](https://github.com/libimobiledevice/libplist)**, **[libusbmuxd](https://github.com/libimobiledevice/libusbmuxd)**, **[libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue)** and **[usbmuxd](https://github.com/libimobiledevice/usbmuxd)**, from the libimobiledevice project. Licensed under LGPL or GPL; see each repository.

### Diagnosis and documentation

- **[Asahi Linux](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)**: documentation on the `Apple_APFS_Recovery` partition and on DFU restores from Linux.
- **Arbifox** and **u/DarthSilicrypt**: [guide for the "Failed to find SFR recovery volume" error](https://www.reddit.com/r/AsahiLinux/comments/1fmnzm5/guide_how_to_fix_failed_to_find_sfr_recovery/), which made it possible to identify the cause.
- **Howard Oakley ([The Eclectic Light Company](https://eclecticlight.co))**: explanations of recovery on Apple silicon Macs.
- **[ipsw.me](https://ipsw.me)**: index of signed firmware and checksums.
- **Apple**: official documentation on the [DFU port](https://support.apple.com/en-us/120694), [DFU mode and revive/restore](https://support.apple.com/guide/apple-configurator-mac/revive-or-restore-a-mac-with-apple-silicon-apdd5f3c75ad/mac) and the [software update servers](https://support.apple.com/en-us/101555).

### This repository

Diagnosis, scripts, testing and documentation: **Juan Francisco González** ([@JuanFranG](https://github.com/JuanFranG)), with assistance from Claude (Anthropic).

---

## License

The scripts and documentation in this repository are released under the [MIT](LICENSE) license.

idevicerestore and the libimobiledevice libraries are **not part of this repository** and keep their own licenses (LGPL / GPL). The macOS firmware (`.ipsw`) belongs to Apple and is **not included or redistributed** here: it is downloaded directly from Apple's servers.
