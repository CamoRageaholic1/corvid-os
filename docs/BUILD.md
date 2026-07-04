# Corvid OS - Build Guide

How to turn this repo into a bootable `corvid-amd64.iso`. The build runs on a
dedicated Linux VM, never on a developer laptop. Everything here targets a
**Proxmox** build VM running Ubuntu 24.04 LTS.

> This repo holds configuration and build scripts only. `lb build` is executed on
> the build VM. Do not attempt it on macOS or any non-Linux host.

## Prerequisites

- A Proxmox host with room for a build VM. Suggested VM sizing:
  - 4 vCPU, 8 GB RAM (more RAM speeds up the squashfs stage).
  - **60 GB+ disk.** The chroot plus the full Parrot toolset plus the ~8-9 GB ISO
    and its intermediates need real headroom. 40 GB is tight; 60-80 GB is safe.
  - A network path to the Ubuntu and Parrot mirrors.
- The repo checked out on the build VM (or synced to it).

## Step 1 - Provision the build VM

`provisioning/proxmox-build-vm.sh` creates the Ubuntu 24.04 VM and installs the
build toolchain: `live-build`, `debootstrap`, `squashfs-tools`, `xorriso`, and
the APT/GPG helpers.

```sh
# On the Proxmox host (or wherever the script is meant to run):
provisioning/proxmox-build-vm.sh
```

If you are provisioning by hand instead, the essential packages on the build VM
are:

```sh
sudo apt update
sudo apt install -y live-build debootstrap squashfs-tools xorriso \
    gnupg ca-certificates
```

## Step 2 - Configure the build tree (`lb config`)

From the repo root on the build VM. This materializes live-build's working tree
from `auto/config`, which sets the Ubuntu mode, the `noble` distribution, and the
amd64 architecture, and wires in this repo's `config/` (archives, package lists,
hooks, includes).

```sh
cd /path/to/corvid
lb config
```

`auto/config` runs the equivalent of:

```sh
lb config \
  --mode ubuntu \
  --distribution noble \
  --architecture amd64 \
  --archive-areas "main restricted universe multiverse"
```

A successful `lb config` leaves a populated build tree and does not download the
base system yet. Re-run it any time you change `auto/config`.

## Step 3 - Build the ISO (`lb build`)

This is the long step. It bootstraps the Kubuntu base, adds the pinned Parrot
repo and key, installs every package list, runs all the hooks, adds Calamares and
boot branding, and squashes it all into an ISO.

```sh
sudo lb build 2>&1 | tee build.log
```

Expect:

- **Output:** `corvid-amd64.iso`, roughly **8 to 9 GB**. That size is intentional;
  it is the price of shipping the full Parrot toolset and the complete dev stack.
- **Time:** on the order of **45 to 90 minutes** on the suggested VM, dominated by
  package downloads and the final squashfs compression. Cold mirror caches and
  slower disks push this higher.
- Always capture the run with `tee build.log`; hook output (including the
  CZD-Tools fetch) is where you confirm each stage worked.

To rebuild from clean:

```sh
sudo lb clean       # remove build artifacts, keep the config
sudo lb clean --purge  # also drop the bootstrap/cache (full cold rebuild)
```

## Step 4 - Smoke-test in QEMU

Boot the freshly built image before doing anything else with it.

```sh
qemu-system-x86_64 -cdrom corvid-amd64.iso -m 4096 -smp 2 \
    -enable-kvm -vga virtio
```

(Drop `-enable-kvm` if the build VM has no nested virtualization.) What to check
on the live boot:

- Reaches the KDE Plasma desktop.
- `czd` launches the CZD-Tools menu (and a "CZD-Tools" entry exists in the Plasma
  launcher).
- AnonSurf is present.
- The Calamares installer opens and offers LUKS full-disk encryption by default.

For an install-to-disk test, attach a scratch disk and run Calamares:

```sh
qemu-img create -f qcow2 corvid-test.qcow2 40G
qemu-system-x86_64 -cdrom corvid-amd64.iso -hda corvid-test.qcow2 \
    -m 4096 -smp 2 -enable-kvm -vga virtio
```

## Troubleshooting

### APT pin conflicts

Symptom: `lb build` fails during package install with unmet dependencies, or a
core package (glibc, python3, systemd) is being pulled from Parrot.

- This means the pin is not doing its job. Confirm `config/archives/` has both the
  Parrot source list and the `.pref` pin, and that Ubuntu/noble is pinned high
  (900+) while Parrot is pinned low (~100).
- On a booted image you can verify with `apt-cache policy <pkg>`: the base should
  win for core libraries; only named security tools should resolve to Parrot.
- If a specific security package drags in a base library from Parrot, pin that
  library explicitly to the base (negative priority for the Parrot origin) rather
  than loosening the whole pin.

### Network / mirror issues

Symptom: bootstrap or package download hangs or 404s.

- Confirm the build VM can reach the Ubuntu mirror and `http.parrot.sh` (or the
  configured Parrot mirror). A proxy or firewall on the Proxmox network is the
  usual culprit.
- Mirror hiccups mid-build are common on large downloads. Re-running `sudo lb
  build` resumes using cached debs where possible; a truly stuck cache clears with
  `sudo lb clean --purge` followed by a fresh build.
- GPG "NO_PUBKEY" or signature errors mean the Parrot archive key did not get
  installed before the repo was used. Check the key handling in
  `config/archives/`.

### CZD-Tools did not make it into the image

Symptom: `czd` reports the payload is missing.

- The `0500-czd-tools` hook tries to clone `CamoRageaholic1/CZD-Tools` and falls
  back to a local stage at `/opt/czd-tools-src`. As of writing that repo is not
  published, so unless it exists or a local source is staged on the build VM, the
  hook warns and continues (the ISO still builds).
- Fix by publishing the repo, or by staging a copy of the suite on the build VM
  and pointing `CZD_TOOLS_LOCAL_SRC` at it, then rebuilding. See the hook header
  and `config/includes.chroot/opt/czd-tools/README.corvid.md`.

### Build runs out of disk

Symptom: build fails late (squashfs or ISO assembly) with no space left.

- The chroot, the compressed filesystem, and the ISO can transiently need well
  over 30 GB combined. Give the VM 60 GB or more and retry.

## Related docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) - how the build is structured and why.
- [`ROADMAP.md`](ROADMAP.md) - arm64 variant and the deferred Secure Boot path.
- [`../SPEC.md`](../SPEC.md) - the authoritative build specification.
