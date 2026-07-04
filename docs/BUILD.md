# Corvid OS - Build Guide

How to turn this repo into a bootable `corvid-amd64.iso`. The build runs on a
Linux host, never on macOS or Windows. Any **Ubuntu 24.04 LTS** environment works:
a VM, an LXC/Docker container, a cloud instance, or bare metal. A homelab
Proxmox convenience provisioner is included, but nothing here is Proxmox-specific.

> This repo holds configuration and build scripts only. `lb build` is executed on
> the Linux build host. Do not attempt it on macOS or any non-Linux host.

## What you get

- **Output:** `corvid-amd64.iso`, a **UEFI-bootable** image. Copy it straight onto
  a Ventoy stick, or `dd`/flash it to a USB drive.
- **Size:** the full image (Parrot toolset + dev stack) runs large, on the order of
  a few GB compressed.
- **Boot mode:** UEFI only (see "Why UEFI-only" below). Boot target machines in UEFI
  mode; Ventoy handles this on modern hardware.

## Prerequisites

Any Ubuntu 24.04 LTS host with:

- **4+ vCPU, 8 GB+ RAM** (more RAM and, especially, **fast disk** help a lot - the
  squashfs compression is disk-I/O-bound and is the single longest stage).
- **60-80 GB free disk.** The chroot, the compressed filesystem, and the ISO plus
  intermediates need real headroom.
- Network access to the Ubuntu and Parrot mirrors.

Install the build toolchain:

```sh
sudo apt update
sudo apt install -y \
    live-build debootstrap ubuntu-keyring \
    squashfs-tools xorriso \
    grub-common grub-efi-amd64-bin dosfstools mtools \
    python3-pil rsync git gnupg ca-certificates
```

- `grub-common grub-efi-amd64-bin dosfstools mtools` - needed by the UEFI remaster
  step (see step 3).
- `python3-pil` (Pillow) - the branding renderer uses it to composite the real
  emblem and wallpaper. Without it the build falls back to placeholder art.

### Optional: homelab Proxmox build VM

If you run Proxmox, `provisioning/proxmox-build-vm.sh` stands up a ready-to-build
Ubuntu 24.04 VM over `qm`-over-SSH. It is one convenience, not a requirement - any
Ubuntu 24.04 host above is equivalent.

```sh
provisioning/proxmox-build-vm.sh   # optional homelab helper
```

## Step 1 - Get the repo onto the build host

Clone it (this is a private repo, so use an authenticated clone or an SSH deploy
key), or `rsync` a working copy across:

```sh
rsync -a --exclude='.git' /path/to/corvid/ builduser@build-host:corvid/
```

## Step 2 - Configure the build tree (`lb config`)

From the repo root on the build host:

```sh
cd corvid
sudo lb config
```

This materializes live-build's working tree from `auto/config` (Ubuntu mode, `noble`,
amd64) and wires in this repo's `config/` (archives, package lists, hooks, includes).
Re-run it any time you change `auto/config`.

For a faster iteration build that skips the slow security-upgrade pass:

```sh
sudo CORVID_SECURITY=false lb config
```

## Step 3 - Build the ISO (`lb build`)

```sh
sudo lb build 2>&1 | tee build.log
```

`auto/build` drives three things: it stages branding, runs `lb build`, then
**remasters the result into a bootable UEFI ISO** (`provisioning/remaster-uefi.sh`).
The remaster step exists because Ubuntu's live-build 3.0 emits an ISO with no boot
record - see below.

Expect the squashfs and package stages to dominate the wall-clock time; on a slow
disk this can run well over an hour. Always capture the run with `tee build.log`.

To rebuild:

```sh
sudo lb clean          # remove build artifacts, keep the config + download cache
sudo lb clean --purge  # also drop the bootstrap/cache (full cold rebuild)
```

## Step 4 - Boot-test in QEMU (UEFI)

Because the image is UEFI-only, test it with OVMF firmware:

```sh
sudo apt install -y qemu-system-x86 ovmf
qemu-system-x86_64 \
    -machine q35 -m 4096 -smp 2 -enable-kvm \
    -bios /usr/share/ovmf/OVMF.fd \
    -cdrom corvid-amd64.iso
```

(Drop `-enable-kvm` if the host has no nested virtualization.) What to check on the
live boot: it reaches the KDE Plasma desktop, `czd` launches the CZD-Tools menu,
AnonSurf is present, and the Calamares installer offers LUKS full-disk encryption by
default.

## Downloads / Releases

Published Corvid OS images and their checksums live here:

- **GitHub Releases:** https://github.com/CamoRageaholic1/corvid-os/releases _(add
  the ISO + `SHA256SUMS` as a release asset)_
- **Mirror (Google Drive):** _link added when an image is published_

Always publish the `sha256` alongside the ISO and verify after download:

```sh
shasum -a 256 corvid-amd64.iso
```

## Why UEFI-only (live-build 3.0 notes)

Ubuntu 24.04 ships the legacy **live-build 3.0**, which behaves differently from
Debian's current live-build. Two consequences shaped `auto/config` and `auto/build`:

1. **The syslinux (BIOS) path is broken on 24.04.** live-build 3.0's syslinux stage
   tries to install `syslinux-themes-ubuntu-oneiric` and `gfxboot-theme-ubuntu` -
   packages from Ubuntu 11.10 that no longer exist - and aborts. So Corvid builds
   with `--bootloader grub-efi` (UEFI) only.
2. **grub-efi builds a bootable filesystem but an ISO with no El Torito boot
   record.** So `provisioning/remaster-uefi.sh` post-processes the ISO: it builds a
   standalone GRUB EFI image, wraps it in an EFI System Partition, and re-masters the
   ISO with a proper UEFI boot entry. `auto/build` calls this automatically.

`auto/config` also drops the Debian-style flags 3.0 does not understand
(`--updates`, `--bootloaders`, `--image-name`, `--debootstrap-options`).

## Troubleshooting

### `lb build` exits non-zero but an ISO still appears

live-build 3.0 fails on an obsolete `isohybrid` (BIOS-MBR) step at the very end even
when the data ISO was written. `auto/build` treats this as non-fatal when the data
ISO is present and proceeds to the UEFI remaster. If you run `lb build` by hand, run
`provisioning/remaster-uefi.sh` afterwards to get the bootable image.

### The live image boots to a shell instead of the desktop

Open item: `--mode ubuntu` produces a casper-based system, but the boot parameters in
`auto/config` currently use Debian live-boot syntax (`boot=live`). If the live session
drops to an initramfs/BusyBox prompt, switch the `--bootappend-live` params to casper's
(`boot=casper`) and rebuild.

### `E: Unable to locate package <name>`

Some KDE package names differ on Ubuntu (for example the screenshot tool is
`kde-spectacle`, not `spectacle`). Fix the offending name in the relevant
`config/package-lists/*.list.chroot` and rebuild.

### APT pin conflicts

Symptom: package install fails with unmet dependencies, or a core package (glibc,
python3, systemd) is pulled from Parrot. Confirm `config/archives/` has both the Parrot
source list and the `.pref` pin, with Ubuntu/noble pinned high (900+) and Parrot low
(~100). On a booted image, `apt-cache policy <pkg>` should show the base winning for
core libraries and only named security tools resolving to Parrot.

### Network / mirror issues

Bootstrap or package download hangs or 404s: confirm the host reaches the Ubuntu mirror
and `deb.parrot.sh`. Re-running `sudo lb build` resumes from cached debs; a truly stuck
cache clears with `sudo lb clean --purge`. GPG "NO_PUBKEY" errors mean the Parrot key
was not installed before the repo was used - check `config/archives/`.

### Build runs out of disk

The chroot, the compressed filesystem, and the ISO can transiently need well over 30 GB
combined. Give the host 60 GB+ and retry.

## Related docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) - how the build is structured and why.
- [`ROADMAP.md`](ROADMAP.md) - arm64 variant and the deferred Secure Boot path.
- [`../SPEC.md`](../SPEC.md) - the authoritative build specification.
