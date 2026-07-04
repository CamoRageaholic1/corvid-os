# Corvid OS — Build Specification (source of truth)

> **Corvid OS** build specification. This document is the single source of
> truth the build is authored against. It defines the locked decisions, the
> repository layout, and the hard technical rules that every part of the build must
> respect. If a decision is not recorded here, it is not settled — resolve it and
> record it here rather than inventing layout ad hoc.

## 1. What this is

A security-minded, coding-first, AI-agent-ready daily driver. Ubuntu LTS underneath
(stability + familiarity), a curated security toolset from Ubuntu's own repositories on
top (with Kali as a pinned fallback), a full dev stack, and built-in AI-agent tooling,
shipped as a KDE Plasma desktop. Built with Debian `live-build`. The whole thing is a git
repo so it doubles as a portfolio artifact.

**"Curated Ubuntu tools + Kali fallback" means:** the security catalog is installed from
Ubuntu's own repositories on the Kubuntu 24.04 LTS base, and Kali's repo is layered on via
APT pinning only as a fallback for the tools Ubuntu does not package. Kali is Debian-based,
not Ubuntu-based, so its fallback packages are pinned low against the fixed LTS base to
avoid version skew and are pulled only when named explicitly. (The earlier
`parrot-tools-full` plan was dropped: Parrot's tools are not cleanly installable on an
Ubuntu base, its `lory` repo does not even carry the tools metapackage, and its
Debian-built tools conflict with Ubuntu libraries.)

## 2. Locked decisions

| Layer | Decision | Notes |
|---|---|---|
| Positioning | **Security-minded, coding-first, AI-agent-ready daily driver** | Stable Ubuntu LTS + KDE Plasma + curated security toolset + full dev stack + built-in AI-agent tooling. Honest, not overhyped |
| Base | Kubuntu 24.04 LTS (`noble`), amd64 primary | Start from Kubuntu, not stock Ubuntu, so Plasma is already correct |
| Build system | Debian `live-build` (`lb`), `--mode ubuntu --distribution noble` | Everything in this repo; ISO built on any Ubuntu 24.04 Linux host (live-build 3.0 -> grub-efi + UEFI remaster) |
| Desktop | KDE Plasma | |
| Tools | **Curated toolset from Ubuntu's own repos** + **Kali repo (APT-pinned) as a fallback** | Dropped `parrot-tools-full`: Parrot's tools are not cleanly installable on an Ubuntu base (its `lory` repo lacks the tools metapackage; its Debian-built tools conflict with Ubuntu libs). Curated set: nmap, sqlmap, hydra, john, aircrack-ng, wireshark, hashcat, gobuster, nikto, binwalk, etc. Kali pinned low for the gaps. Plus AnonSurf (git graft) and CZD-Tools. ISO is sized by the curated set, not a full catalog |
| AI-agent tooling | **`corvid-ai-setup`** installer menu | Offers to install AI coding agents + local LLM runtimes: Claude Code, OpenAI Codex CLI, Google Gemini CLI, Aider, Ollama, LM Studio, Hermes (Nous Research). Reachable as `corvid-ai-setup` in a terminal or from the Plasma menu. Installs on demand, never auto-runs |
| Security DNA (v1) | AnonSurf/Tor · LUKS-default installer · hardened kernel sysctl + AppArmor enforce · encrypted live persistence | |
| Security DNA (add-on, NOT v1) | **Secure Boot / MOK** | Deferred. Document the path in `docs/ROADMAP.md`, don't implement |
| Dev stack | Python, Go, Rust, Node, Ruby, C/C++ · VS Code + Neovim · Docker + distrobox · CZD-Tools baked in | |
| Installer | Calamares, LUKS full-disk-encryption default | Not Ubiquity/subiquity — Calamares rebrands cleanly for KDE |
| Targets | amd64 (v1.0) · arm64/Pi 5 (v1.1) · VM appliance variant | arm64 uses **Kali's** arm64 repo as its fallback (Kali has the ARM coverage) |
| Milestone | Full-featured v1 (everything in one image) | Smoke ISO already boot-tested to KDE Plasma in a UEFI VM; full build in progress |

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
│   ├── archives/                               Kali fallback repo list + pin file (PINNING) + GPG key
│   ├── package-lists/
│   │   ├── base.list.chroot                    base system packages
│   │   ├── desktop.list.chroot                 KDE Plasma
│   │   ├── devstack.list.chroot                languages, docker, distrobox, editors
│   │   └── security.list.chroot                curated Ubuntu security tools + named Kali fallbacks
│   ├── hooks/live/
│   │   ├── 0100-0399  security/harden/anonsurf
│   │   ├── 0400-0499  devstack config
│   │   ├── 0500-0599  czd-tools + corvid-ai-setup (AI-agent installer)
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

1. **APT pinning is mandatory.** The pin file in `config/archives/` pins Ubuntu/noble as the
   default (Pin-Priority 900+) and the Kali fallback repo LOW (e.g. 100) so only explicitly
   requested security packages that Ubuntu lacks pull from Kali. Never let Kali override
   glibc/libc6/python3/core libs. This is the single detail that keeps the LTS base from
   breaking. Include the Kali archive GPG key. Most of the curated toolset comes straight from
   Ubuntu's own repos and needs no pin; the pin exists only to make the Kali fallback safe.
2. **This repo holds configuration only; `lb build` runs on a Linux host.** No build runs on
   a non-Linux host. The build runs on any Ubuntu 24.04 Linux host; a homelab helper,
   `provisioning/proxmox-build-vm.sh`, is optional. Scripts are validated with `bash -n` and
   shellcheck where available, not by executing the build locally.
3. **CZD-Tools is not vendored.** The hook clones from GitHub (`CamoRageaholic1`) or copies from
   `~/CZD-Tools` at build time into `/opt/czd-tools` and drops a launcher on PATH. Do not commit
   a copy of the whole suite into this repo.
4. **arm64 ≠ amd64 toolset.** The amd64 build's Kali fallback is the amd64 repo; the Pi 5 build
   sources its fallback tools from Kali's arm64 repo. Keep arm64 as a separate variant,
   documented, not blocking amd64 v1.
5. **AnonSurf is a graft.** AnonSurf is not in Ubuntu's repos; the hook installs + enables it
   from ParrotSec's upstream source (git) on the Ubuntu base and must handle the systemd unit +
   iptables/nftables rules explicitly.
6. **No Secure Boot in v1.** Document the MOK-enrollment path only.
7. **Hooks are ordered by number.** `config/hooks/live/` scripts run in filename order inside
   the chroot. The number bands (`0100-0399` security, `0400-0499` devstack, `0500-0599`
   CZD-Tools and the `corvid-ai-setup` AI-agent installer, `0600-0699` branding) fix the load
   order: hardening and tooling land before branding, and the gaps leave room to insert steps
   later without renumbering.

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

- `lb config && lb build` produces a bootable amd64 ISO with Plasma, the curated security
  toolset (Ubuntu repos + named Kali fallbacks), the dev stack, CZD-Tools, AnonSurf, hardened
  sysctl/AppArmor.
- `corvid-ai-setup` is present and can install the AI coding agents and local LLM runtimes
  (Claude Code, OpenAI Codex CLI, Google Gemini CLI, Aider, Ollama, LM Studio, Hermes).
- Calamares installs to disk with LUKS FDE by default.
- Live USB supports encrypted persistence.
- README is portfolio-grade (screenshots placeholder, architecture, "why", build steps).
- arm64 variant + Secure Boot are documented as roadmap, not shipped.

Verification status: the smoke ISO has been built and boot-tested in a UEFI VM (reaches the
KDE Plasma desktop with the Calamares installer present); the full-featured build above is in
progress.
