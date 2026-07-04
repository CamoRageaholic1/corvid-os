# Corvid OS — Build Specification (source of truth)

> **Corvid OS** build specification. This document is the single source of
> truth the build is authored against. It defines the locked decisions, the
> repository layout, and the hard technical rules that every part of the build must
> respect. If a decision is not recorded here, it is not settled — resolve it and
> record it here rather than inventing layout ad hoc.

## 1. What this is

A security-hardened, coding-friendly Linux distribution for advanced users. Ubuntu LTS
underneath (stability + familiarity), Parrot's security tooling on top (pentest catalog),
shipped as a KDE Plasma desktop. Built with Debian `live-build`. The whole thing is a git
repo so it doubles as a portfolio artifact.

**"Mix Ubuntu and Parrot" means:** Kubuntu 24.04 LTS base system + Parrot security repo
layered on via APT pinning. Parrot is Debian-based, not Ubuntu-based, so the tools come
from Parrot's repo, pinned against the fixed LTS base to avoid version skew.

## 2. Locked decisions

| Layer | Decision | Notes |
|---|---|---|
| Base | Kubuntu 24.04 LTS (`noble`), amd64 primary | Start from Kubuntu, not stock Ubuntu, so Plasma is already correct |
| Build system | Debian `live-build` (`lb`), `--mode ubuntu --distribution noble` | Everything in this repo; ISO built on any Ubuntu 24.04 Linux host (live-build 3.0 -> grub-efi + UEFI remaster) |
| Desktop | KDE Plasma | |
| Tools | **Parrot repo, APT-pinned**, **full metapackage** (`parrot-tools-full` or equiv) | Big ISO (~8-9GB) is expected and accepted |
| Security DNA (v1) | AnonSurf/Tor · LUKS-default installer · hardened kernel sysctl + AppArmor enforce · encrypted live persistence | |
| Security DNA (add-on, NOT v1) | **Secure Boot / MOK** | Deferred. Document the path in `docs/ROADMAP.md`, don't implement |
| Dev stack | Python, Go, Rust, Node, Ruby, C/C++ · VS Code + Neovim · Docker + distrobox · CZD-Tools baked in | |
| Installer | Calamares, LUKS full-disk-encryption default | Not Ubiquity/subiquity — Calamares rebrands cleanly for KDE |
| Targets | amd64 (v1.0) · arm64/Pi 5 (v1.1) · VM appliance variant | arm64 uses **Kali's** arm repo, not Parrot (coverage gap) |
| Milestone | Full-featured v1 (everything in one image) | |

Name/branding string lives in ONE place: `branding/os-release` + a `CORVID_NAME` build var.
Rename = change that, nothing else hardcodes the name.

## 3. Repository layout

The tree below defines where each part of the build lives and what each directory is
for. Build-time configuration is organized by concern so that any one piece can be
reasoned about in isolation. Hook filenames are numbered so `live-build` runs them in a
deterministic load order (see rule 7).

```
corvid/
├── SPEC.md, README.md, .gitignore            spec + portfolio overview + ignores
├── auto/                                       live-build auto/{config,build,clean} wrappers
├── provisioning/proxmox-build-vm.sh            stands up the Ubuntu 24.04 build VM
├── config/
│   ├── archives/                               Parrot repo list + pin file (PINNING) + GPG key
│   ├── package-lists/
│   │   ├── base.list.chroot                    base system packages
│   │   ├── desktop.list.chroot                 KDE Plasma
│   │   ├── devstack.list.chroot                languages, docker, distrobox, editors
│   │   └── security.list.chroot                parrot-tools-full metapackage
│   ├── hooks/live/
│   │   ├── 0100-0399  security/harden/anonsurf
│   │   ├── 0400-0499  devstack config
│   │   ├── 0500-0599  czd-tools
│   │   └── 0600-0699  branding
│   ├── includes.chroot/
│   │   ├── etc/sysctl.d/                        hardening drop-ins
│   │   ├── etc/apparmor.d/local/                local AppArmor overrides
│   │   ├── etc/skel/                            nvim + vscode dotfiles
│   │   ├── etc/os-release  (via branding hook)  distro identity
│   │   └── opt/czd-tools/                       CZD-Tools install/link wiring (NOT vendored copy)
│   ├── includes.binary/                        ISO boot branding
│   └── bootloaders/                            [unused in v1 — Secure Boot deferred]
├── calamares/                                  installer config, LUKS default
├── branding/                                   os-release, wallpaper, plymouth, logo
├── arm64/                                      Pi 5 variant (Kali arm repo)
└── docs/
    ├── ARCHITECTURE.md, BUILD.md               how the build is structured, and how to run it
    └── ROADMAP.md                              future work, incl. Secure Boot add-on
```

## 4. Hard technical rules

1. **APT pinning is mandatory.** `config/archives/parrot.pref.chroot` pins Ubuntu/noble as the
   default (Pin-Priority 900+) and the Parrot repo LOW (e.g. 100) so only explicitly requested
   security packages pull from Parrot. Never let Parrot override glibc/libc6/python3/core libs.
   This is the single detail that keeps the LTS base from breaking. Include the Parrot GPG key.
2. **This repo holds configuration only; `lb build` runs on a Linux host.** No build runs on
   a non-Linux host. The build runs on any Ubuntu 24.04 Linux host; a homelab helper,
   `provisioning/proxmox-build-vm.sh`, is optional. Scripts are validated with `bash -n` and
   shellcheck where available, not by executing the build locally.
3. **CZD-Tools is not vendored.** The hook clones from GitHub (`CamoRageaholic1`) or copies from
   `~/CZD-Tools` at build time into `/opt/czd-tools` and drops a launcher on PATH. Do not commit
   a copy of the whole suite into this repo.
4. **arm64 ≠ amd64 toolset.** Parrot's repo is amd64-centric; the Pi 5 build sources tools from
   Kali's arm64 repo. Keep arm64 as a separate variant, documented, not blocking amd64 v1.
5. **AnonSurf is a graft.** It's a Parrot package; the hook installs + enables it on the Ubuntu
   base and must handle the systemd unit + iptables/nftables rules explicitly.
6. **No Secure Boot in v1.** Document the MOK-enrollment path only.
7. **Hooks are ordered by number.** `config/hooks/live/` scripts run in filename order inside
   the chroot. The number bands (`0100-0399` security, `0400-0499` devstack, `0500-0599`
   CZD-Tools, `0600-0699` branding) fix the load order: hardening and tooling land before
   branding, and the gaps leave room to insert steps later without renumbering.

## 5. Build/run flow (runs on any Ubuntu 24.04 Linux host)

Builds on any Ubuntu 24.04 host (VM, container, cloud, or bare metal) with
live-build. `provisioning/proxmox-build-vm.sh` is an optional homelab helper.

```
lb config     (from auto/config)     # materialize the build tree
lb build      (from auto/build)      # build + remaster -> bootable corvid-amd64.iso (UEFI)
qemu-system-x86_64 -machine q35 -bios /usr/share/ovmf/OVMF.fd -cdrom corvid-amd64.iso -m 4096
```

Ubuntu ships live-build 3.0, which needs `--bootloader grub-efi` (its syslinux path is
broken on noble) and emits an ISO with no boot record; `provisioning/remaster-uefi.sh`
(called by auto/build) adds the UEFI boot record. Result is UEFI-only. See docs/BUILD.md.

## 6. Definition of done (v1)

- `lb config && lb build` produces a bootable amd64 ISO with Plasma, the full Parrot toolset,
  the dev stack, CZD-Tools, AnonSurf, hardened sysctl/AppArmor.
- Calamares installs to disk with LUKS FDE by default.
- Live USB supports encrypted persistence.
- README is portfolio-grade (screenshots placeholder, architecture, "why", build steps).
- arm64 variant + Secure Boot are documented as roadmap, not shipped.
