# Corvid OS - Build Guide (arm64 / Raspberry Pi 5)

How to turn this repo into a bootable Raspberry Pi 5 image, `corvid-pi5-arm64.img.xz`.
This is the arm64 companion to [`BUILD.md`](BUILD.md), which covers the amd64 ISO.
Read that one first if you have not; this guide only covers what is different for the
Pi.

The build runs on a Linux host, never on macOS or Windows. You have two host options:

- An **x86_64 Ubuntu 24.04 host** (the same kind of machine that builds the amd64
  ISO), plus an emulation layer so it can run arm64 programs. This is the
  "cross-build" path.
- An **arm64 Linux host** (another Raspberry Pi, an arm64 cloud instance, or an
  arm64 VM). This is the "native" path and needs no emulation.

> This repo holds configuration and build scripts only. The build itself is run on
> the Linux build host. Do not attempt it on macOS.

## What "arm64" and "cross-build" mean

- **arm64** (also written **aarch64**) is the 64-bit ARM processor architecture the
  Raspberry Pi 5 uses. It is a different instruction set from the **amd64** (also
  written **x86_64**) chips in most laptops and servers. A program compiled for one
  will not run on the other.
- **Cross-build** means building software for a different architecture than the one
  the build host runs. To assemble an arm64 system on an x86_64 host, the host has to
  be able to run arm64 helper programs (the package manager's hooks, for example).
  That is what the emulation layer below provides.

## What you get

- **Output:** `corvid-pi5-arm64.img.xz`. This is a full SD-card / USB image
  (a byte-for-byte disk layout with the boot and root partitions already laid down),
  compressed with **xz** (a high-ratio compressor, the `.xz` on the end). You flash
  it whole onto the Pi's storage.
- **Size:** the curated Ubuntu toolset plus the dev stack makes this a multi-GB image.
  The `.xz` compression cuts the download size substantially; it expands back to the
  full size when flashed.
- **Boot target:** a Raspberry Pi 5. The Pi uses its own bootloader chain (not the
  UEFI firmware a PC uses), so none of the amd64 UEFI remaster steps apply here.

## The pieces this build reuses UNCHANGED from the amd64 tree

The whole point of the arm64 variant is to keep one codebase and one mental model. The
following are shared as-is; the Pi build copies them in without edits:

- **Every hook under `config/hooks/`.** The firewall prep, AppArmor enforcement,
  AnonSurf install, dev-stack config, CZD-Tools fetch, the **`0600` branding** hook,
  the first-boot finalizer enablement, the AI-setup mode fix, and the
  **`0900-kali-runtime-repo`** hook all run the same on arm64. They are
  architecture-independent shell scripts.
- **The Kali runtime fallback repo and its keyring.** `0900-kali-runtime-repo.chroot`
  writes the dormant Kali source list and pin, and the Kali archive key ships at
  `config/includes.chroot/etc/apt/keyrings/kali-archive-keyring.gpg`. On the Pi this
  same machinery points at Kali's **arm64** packages. It stays dormant (pinned so
  Ubuntu always wins) until the user asks for a Kali-only tool by name at runtime.
- **The `corvid-ai-setup` runtime installer.** The single script serves both images.
  It detects the architecture at launch (`CORVID_ARCH`) and, on arm64, cleanly
  declines the four installers whose upstreams ship no arm64 Linux build (LM Studio,
  Cursor, Windsurf, Jan) instead of downloading an x86 binary that cannot run.

## What is DIFFERENT for the Pi

- **Base + desktop + tool package lists** come from `config-pi5/package-lists/`
  (`desktop.list`, `security.list`, `devstack.list`) instead of the amd64
  `config/package-lists/*.list.chroot`. The security and dev lists port 1:1 (Ubuntu
  builds those tools for arm64); the desktop list is trimmed to `kubuntu-desktop`
  plus `sddm` because the metapackage pulls the rest.
- **The APT pin for the Kali fallback** lives at
  [`arm64/parrot-or-kali-pin.pref`](../arm64/parrot-or-kali-pin.pref). It keeps
  Ubuntu/noble authoritative (high priority) and Kali's arm64 repo low, so Kali only
  ever supplies a security tool you request by name and never a core library. The
  matching Kali arm64 source line is [`arm64/security.list`](../arm64/security.list).
- **No UEFI remaster.** The amd64 build post-processes its ISO into a UEFI-bootable
  disc. The Pi image is written directly with the Pi's own boot partition, so that
  step is skipped entirely.

## Prerequisites

### Common to both host types

- **60-80 GB free disk.** The arm64 root filesystem, the raw image, and the
  compressed `.xz` need real headroom while they exist side by side.
- **4+ CPU cores, 8 GB+ RAM.** On the emulated x86_64 path, emulation makes the arm64
  package stage noticeably slower, so more cores help.
- Network access to the Ubuntu arm64 mirror (`ports.ubuntu.com`, which is where
  Ubuntu serves non-amd64 architectures) and to the Kali mirror for the keyring.

### Extra step for the x86_64 (cross-build) host only

Install the emulation layer so the x86_64 host can run arm64 helper programs during
the build:

```sh
sudo apt update
sudo apt install -y qemu-user-static binfmt-support
```

- **`qemu-user-static`** is an emulator that runs a single arm64 program on an x86_64
  machine. The "static" build has no external library dependencies, so it works inside
  the build's chroot (the isolated mini root filesystem the image is assembled in).
- **binfmt** (binary format) is the Linux kernel feature that says "when you are asked
  to run an arm64 program, hand it to qemu automatically." `binfmt-support` registers
  qemu for arm64 so this happens transparently.

Confirm the arm64 handler is registered before you build:

```sh
ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64
```

You should see an `aarch64` (or `qemu-aarch64`) entry. If you see nothing, re-run the
install above, or on some hosts run `sudo systemctl restart systemd-binfmt`.

An **arm64 host needs none of this** - it runs arm64 programs natively, so skip the
qemu and binfmt steps.

## Step 1 - Get the repo onto the build host

Same as the amd64 build. Clone it (authenticated, since it is private) or `rsync` a
working copy across:

```sh
rsync -a --exclude='.git' /path/to/corvid/ builduser@build-host:corvid/
```

## Step 2 - Run the Pi build script

From the repo root on the build host:

```sh
cd corvid
sudo provisioning/build-pi5.sh
```

`build-pi5.sh` is the single entrypoint for the Pi image. It:

1. Bootstraps an **Ubuntu 24.04 (noble) arm64** root filesystem from the Ubuntu ports
   mirror. On the x86_64 host this runs under qemu emulation automatically; on an
   arm64 host it runs natively.
2. Installs the packages named in `config-pi5/package-lists/desktop.list`,
   `security.list`, and `devstack.list`.
3. Copies in the shared pieces from the amd64 tree without editing them: the
   `config/hooks/` scripts (branding, AnonSurf, dev stack, CZD-Tools, first-boot,
   AI-setup, and the dormant Kali runtime repo), the
   `config/includes.chroot/` file overlay (which includes `corvid-ai-setup` and the
   Kali keyring), and the arm64 Kali pin from `arm64/parrot-or-kali-pin.pref` plus the
   Kali arm64 source from `arm64/security.list`.
4. Lays down the Raspberry Pi boot partition and firmware so the Pi can start the
   image.
5. Packs the result into `corvid-pi5-arm64.img.xz`.

**Inputs:** this repo (config-pi5 lists + the reused amd64 `config/` tree + the
`arm64/` pin and source stubs).
**Output:** `corvid-pi5-arm64.img.xz` in the repo root (alongside a `.sha256`
checksum file).

Capture the run so you can debug a failure:

```sh
sudo provisioning/build-pi5.sh 2>&1 | tee build-pi5.log
```

The bootstrap and package stages dominate the wall-clock time, and emulation makes the
x86_64 path slower than a native arm64 build. Expect a long run on the cross-build
path.

## Step 3 - Verify the image

Always publish and check the checksum next to the image:

```sh
sha256sum corvid-pi5-arm64.img.xz
```

Compare it to the `.sha256` file the build wrote. A mismatch means a corrupted or
truncated image; rebuild or re-download before flashing.

## Step 4 - Flash the image to the Pi's storage

You are writing the image onto the SD card or USB/NVMe drive the Pi will boot from.
**This erases the target device completely**, so identify it carefully.

### Option A - Raspberry Pi Imager (recommended, cross-platform GUI)

Raspberry Pi Imager is the official flashing tool and runs on macOS, Windows, and
Linux. It decompresses the `.xz` for you, so you do not extract it first.

1. Install it from https://www.raspberrypi.com/software/ and open it.
2. Click **Choose OS**, scroll to the bottom, and pick **Use custom**.
3. Select `corvid-pi5-arm64.img.xz`.
4. Click **Choose Storage** and select your SD card or USB/NVMe drive. Double-check
   the device: the tool shows its size and name, and the wrong choice wipes the wrong
   disk.
5. Click **Write** and confirm. It writes, then verifies, then ejects.

Leave the Imager's OS-customization prompt alone (do not preset a user or Wi-Fi).
Corvid runs Ubuntu's own first-boot account setup, described in Step 5.

### Option B - `dd` (Linux/macOS command line)

`dd` is the low-level disk copy tool. It is precise and unforgiving: the wrong `of=`
target destroys that disk with no undo. Use this only if you are comfortable
identifying block devices.

First find the target device name:

- Linux: `lsblk` (it will look like `/dev/sdX` or `/dev/mmcblk0`).
- macOS: `diskutil list` (it will look like `/dev/diskN`), then
  `diskutil unmountDisk /dev/diskN` before writing.

Then decompress and write in one pipe. Replace `/dev/sdX` with YOUR device:

```sh
# Linux
xz -dc corvid-pi5-arm64.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

# macOS (note the 'r' in rdiskN for the raw, faster device)
xz -dc corvid-pi5-arm64.img.xz | sudo dd of=/dev/rdiskN bs=4m
```

- `xz -dc` decompresses the image to standard output without unpacking a temp file.
- `bs=4M` sets a 4-megabyte block size (faster than the tiny default).
- `conv=fsync` / the final `sync` makes sure every byte is flushed to the card before
  `dd` returns. Run `sync` afterward on macOS, then eject the card.

When the write finishes, move the card/drive to the Pi 5.

## Step 5 - First boot

Insert the flashed storage into the Pi 5, connect a monitor, keyboard, and power, and
turn it on.

1. **Ubuntu's stock account setup runs first.** Corvid does not preset a username or
   password. On first boot the standard Ubuntu setup prompts you to create your user
   account, set a password, pick a hostname, and choose locale/keyboard, the same as a
   fresh Ubuntu install. This is deliberate: shipping a baked-in default login would be
   a security hole.
2. **The first-boot finalizer runs once, in the background.** After your account
   exists, `corvid-firstboot.service` finishes the wiring that could not be done at
   build time because your user did not exist yet: it creates the `docker` group, adds
   your account to it, allocates the rootless-container ID ranges, enables the Docker
   socket, then disables itself so it never runs again. This is the same finalizer the
   amd64 image uses.
3. **You reach the KDE Plasma desktop** (from `kubuntu-desktop`), logged in through
   SDDM.
4. **Install AI agents on demand with `corvid-ai-setup`.** Nothing AI-related is
   installed at build time. When you want an agent or a local LLM runtime, launch the
   installer (from its desktop entry or by running `corvid-ai-setup` in a terminal) and
   pick from the menu. On the Pi the script knows it is on arm64: the CLI agents
   (Claude Code, Codex, Gemini), the pipx tools (Aider, OpenHands, llm, shell-gpt, Open
   WebUI), Ollama, fabric, mods, Goose, Hermes, the MCP servers, and the VS Code AI
   extensions all install normally, while the four x86-only desktop apps (LM Studio,
   Cursor, Windsurf, Jan) print a short "not available on arm64 Linux" notice and
   return to the menu instead of installing a broken binary.
5. **Kali-only tools stay a runtime opt-in.** The dormant Kali arm64 fallback repo is
   already configured but pinned so it never touches the base. Pull a Kali-exclusive
   tool only when you need it:

   ```sh
   sudo apt update
   sudo apt install -t kali-rolling metasploit-framework
   ```

## Troubleshooting

### `build-pi5.sh` fails early with an "Exec format error"

The x86_64 host cannot run arm64 programs, which means the qemu/binfmt layer is not
active. Re-check Step 0: install `qemu-user-static binfmt-support`, confirm an
`aarch64` entry exists under `/proc/sys/fs/binfmt_misc/`, and restart
`systemd-binfmt` if needed. On a native arm64 host this error should never appear.

### `E: Unable to locate package <name>`

A package name differs on Ubuntu arm64, or a tool is genuinely not built for arm64.
Fix the name in the relevant `config-pi5/package-lists/*.list` file and rebuild. If a
security tool truly has no arm64 build, move it under the
"arm64-unavailable, covered by the Kali arm64 runtime fallback" section at the bottom
of `security.list` (do not delete it) so it is pulled from the Kali arm64 runtime repo
instead.

### APT pin conflicts (a core library tries to come from Kali)

Confirm `arm64/parrot-or-kali-pin.pref` was applied, with Ubuntu pinned high and Kali
pinned low. On a booted image, `apt-cache policy <pkg>` should show the Ubuntu base
winning for core libraries (glibc, python3, systemd) and only named security tools
resolving to Kali.

### The Pi does not boot / no display

Confirm you flashed the whole `.img.xz` (not an extracted partial file), that the
checksum matched before flashing, and that the storage is seated properly. Re-flash
with Raspberry Pi Imager, which verifies the write automatically.

## Related docs

- [`BUILD.md`](BUILD.md) - the amd64 ISO build (read first).
- [`../arm64/README.md`](../arm64/README.md) - the arm64 variant design and the Kali
  arm64 repo/pin stubs.
- [`ROADMAP.md`](ROADMAP.md) - where the arm64 / Pi 5 variant sits in the plan.
- [`../SPEC.md`](../SPEC.md) - the authoritative build specification.
