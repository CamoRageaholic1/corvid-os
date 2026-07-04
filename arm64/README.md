# Corvid OS - arm64 / Raspberry Pi 5 variant

Status: **v1.1 target. Not part of the amd64 v1.0 release and not a blocker for it.**
This directory holds the design and the config stubs for the ARM build. The amd64
image (`corvid-amd64.iso`) ships first; the Pi variant follows.

See `SPEC.md` section 2 (Targets row) and hard rule 4.

## Why this is a separate variant

The amd64 image layers **Parrot's** security repo onto a Kubuntu 24.04 base. That
works because Parrot ships a large, well-maintained amd64 catalog. On ARM the story
is different: Parrot's repo is amd64-centric and its arm64 coverage is thin. Trying
to reuse the amd64 recipe on a Pi would leave most of the pentest toolset missing.

So the ARM build keeps the same *idea* (a stable base plus a pinned security repo)
but swaps the tool source:

| Layer | amd64 (v1.0) | arm64 / Pi 5 (v1.1) |
|---|---|---|
| Base system | Kubuntu 24.04 LTS (noble), amd64 | Ubuntu 24.04 LTS (noble) arm64 + KDE, or Raspberry Pi OS (64-bit) |
| Security tools | Parrot repo, APT-pinned | **Kali arm64 repo (`kali-rolling`), APT-pinned** |
| Tool metapackage | `parrot-tools-full` (or equivalent) | `kali-linux-large` / `kali-linux-default` (see below) |
| Desktop | KDE Plasma | KDE Plasma |
| AnonSurf | Parrot `anonsurf` | Kali `kali-anonsurf` |

The pinning discipline is identical to amd64: the LTS base stays authoritative
(Pin-Priority high) and the Kali repo is pinned LOW so it only supplies the
security packages you ask for by name, never core libraries (glibc, python3, etc).
This is the single rule that keeps the base from breaking, on both architectures.

## Two viable build paths

Pick one when the variant is actually built. Both are documented here so the
choice can be made when it's time; neither is wired into the default
`lb config` yet.

### Path A - Ubuntu 24.04 arm64 + live-build (mirrors amd64)

Reuse this repo's live-build recipe with `--architecture arm64` and an arm64
bootstrap mirror, then add the Kali repo via the stub files in this directory.
This keeps a single codebase and a single mental model across both images. The
tradeoff is that arm64 live-build with a KDE desktop and cross-arch bootstrap is
fiddlier than amd64 and usually wants an arm64 builder (a Pi, an arm64 VM, or
`qemu-user-static` binfmt for cross-build).

### Path B - Raspberry Pi image + apt-add Kali repo with pinning

Start from a maintained Pi image (Raspberry Pi OS 64-bit, or Ubuntu Server 24.04
arm64 for the Pi), install KDE Plasma, then add the Kali arm64 repo with the pins
in this directory and `apt install` the metapackage. This is the faster route to a
booting Pi and leans on Kali's own well-tested arm64 packaging. Kali also publishes
`build-scripts` / `live-build-config` for arm devices that can be adapted if a
fully custom Pi image is wanted.

Recommendation: prototype with Path B (fast feedback on real hardware), then fold
the result back toward Path A if a single unified live-build recipe is worth it.

## Package-list differences from amd64

The amd64 `config/package-lists/security.list.chroot` installs `parrot-tools-full`.
On ARM that name does not exist. Use Kali's metapackages instead:

- `kali-linux-default` - the standard Kali toolset. Good balance of size and coverage.
- `kali-linux-large` - closer to "everything", the nearest analog to `parrot-tools-full`.
- `kali-linux-headless` - no GUI tools, if a slimmer Pi image is wanted.

Plus `kali-anonsurf` to graft AnonSurf onto the base (same role as the amd64 hook).

Desktop packages also differ slightly: on Ubuntu arm64 use `kubuntu-desktop`; on a
Debian/Kali base use `kali-desktop-kde` or `task-kde-desktop`. The dev stack
(Python/Go/Rust/Node/Ruby/C, Docker, distrobox, VS Code, Neovim) is largely
arch-independent, though VS Code and Docker come from their arm64 channels.

## CZD-Tools on ARM

No change needed. The `0500-czd-tools` hook is architecture-independent: it fetches
the pure-Python launcher and installs `python3` + `git` + `pip` + `pipx`. The
launcher installs each tool on demand and already probes for `apt` at runtime, so
it works the same on a Pi.

## Files in this directory (stubs)

- `parrot-or-kali-pin.pref` - APT preferences: Ubuntu/noble base pinned high,
  Kali `kali-rolling` pinned low. This is the ARM analog of the amd64
  `config/archives/parrot.pref.chroot`. Named to make the "Kali instead of Parrot"
  choice explicit.
- `security.list` - the Kali arm64 APT source line (signed-by the Kali keyring).
  ARM analog of the amd64 `config/archives/parrot.list.chroot`.

These are reference stubs. When the variant is built they are copied into the ARM
build tree (under `config/archives/` for a live-build run, or `/etc/apt/` for a
Pi-image run) alongside the Kali archive keyring. They are deliberately kept out of
the amd64 build tree so they never affect the v1.0 image.

## Open items

- Decide Path A vs Path B before committing arm64 build effort.
- Confirm the Kali archive keyring delivery (package `kali-archive-keyring` from
  Kali, or fetch and place `kali-archive-keyring.gpg` under `/usr/share/keyrings/`).
- Pick the Kali metapackage tier (`kali-linux-default` vs `kali-linux-large`) for
  the target Pi 5 storage budget.
