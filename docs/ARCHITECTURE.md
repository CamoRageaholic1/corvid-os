# Corvid OS - Architecture

How the pieces fit together, and why the major choices were made. The build
specification in [`../SPEC.md`](../SPEC.md) is the source of truth; this document
explains the reasoning and the layout behind it.

## The one-sentence model

Corvid is a Kubuntu 24.04 LTS base with a curated security toolset from Ubuntu's own
repositories (and Kali pinned as a fallback for the gaps), a full dev stack, and
built-in AI-agent tooling, assembled into a KDE Plasma live image by Debian
`live-build` and configured by a set of ordered build hooks.

## Build flow (live-build)

`live-build` (the `lb` command) turns this repo into an ISO in a sequence of
stages. Corvid drives it in Ubuntu mode against the noble release:

```
lb config   -->  materialize the build tree from auto/config
   |              (writes the live-build config/ scaffolding)
   v
bootstrap   -->  debootstrap a minimal Kubuntu 24.04 (noble) chroot
   |
   v
chroot      -->  add archives (Kali fallback repo + pin + key)
   |             install the package lists (base/desktop/devstack/security)
   |             run config/hooks/live/* in numeric order
   v
binary      -->  add the installer (Calamares), ISO boot branding,
   |             assemble the squashfs and bootloader
   v
corvid-amd64.iso   (UEFI-bootable, via the grub-efi + xorriso remaster)
```

Two rules govern this pipeline and appear throughout the repo:

1. **APT pinning is mandatory.** The base is authoritative; the Kali fallback repo is
   a low-priority add-on source used only for tools Ubuntu does not package. Details
   below.
2. **This repo holds configuration only.** No one runs `lb build` on a laptop. The
   build happens on any Ubuntu 24.04 Linux host, such as a provisioned Proxmox VM (see
   [`BUILD.md`](BUILD.md)). Scripts are validated with `bash -n` and shellcheck, not by
   executing the build.

## Why Kubuntu base + a curated toolset with a Kali fallback

The core design tension is "stable daily driver" versus "current security
toolset". Corvid resolves it by drawing the toolset from the base's own
repositories wherever possible, and reaching to a pinned Kali fallback only for
the tools the base lacks.

- **Base: Kubuntu 24.04 LTS (noble).** LTS gives years of support and a base that
  does not move under you. Starting from Kubuntu specifically (rather than stock
  Ubuntu plus a desktop) means Plasma is already correct, so the desktop is not a
  retrofit.
- **Tools: curated from Ubuntu's own repos.** Ubuntu already packages most of the
  catalog Corvid wants (nmap, sqlmap, hydra, john, aircrack-ng, wireshark,
  hashcat, gobuster, nikto, binwalk, and more). Installing these from the base's
  own repositories means they move in lockstep with the base and carry no
  cross-distro dependency risk at all.
- **Fallback: Kali repo, pinned low.** For the handful of tools Ubuntu does not
  package, Kali's repo is added as a fallback. Kali is Debian-based, not
  Ubuntu-based, so its packages are close enough to install against a noble base
  but different enough that they must never be allowed to satisfy core
  dependencies. The pin (Ubuntu/noble at Pin-Priority 900+, Kali at ~100) means
  Kali packages are installable only when named explicitly, and can never win a
  version race for `glibc`/`libc6`, `python3`, `systemd`, or other base libraries.
  That single discipline is what keeps the LTS base from breaking. The Kali
  archive GPG key is added alongside the source. This lives under
  `config/archives/`.

Because the bulk of the toolset comes straight from the base's repositories, the
resulting ISO is sized by the curated set rather than by a full pentest catalog.

### Why not `parrot-tools-full`

The original plan layered Parrot's `parrot-tools-full` metapackage on the Ubuntu
base via pinning. It was dropped because it does not work cleanly on an Ubuntu
base: Parrot's current `lory` repository does not even carry the tools
metapackage, and Parrot's Debian-built tools conflict with the libraries Ubuntu
ships. Sourcing the catalog from Ubuntu's own repos, with Kali only as a narrow
named fallback, avoids that conflict entirely.

### Approaches that were rejected

- **Linux From Scratch (LFS).** Building the whole userland from source would give
  total control but throws away the entire value proposition: LTS stability,
  security updates, and a maintained package ecosystem. It would turn a
  distribution-assembly project into an indefinite maintenance burden with no
  upstream to lean on. Rejected.
- **Snaps for the toolset.** Snap packaging of security tools is sparse,
  inconsistent, and adds confinement and startup friction that fights the way
  pentest tools expect to touch the network and filesystem. Native `.deb`
  packages from Ubuntu's own repos (and the pinned Kali fallback) install
  directly and behave as the tools expect. Rejected in favor of native packages.
- **Just shipping Kali or Parrot as-is.** That would give the tools but not the
  stable LTS base, the specific dev-stack curation, the AI-agent tooling, or the
  branding and hardening posture Corvid defines. The point of Corvid is the
  combination.

## Hook numbering scheme

All build-time configuration happens through scripts in `config/hooks/live/`,
which `live-build` runs in filename order inside the chroot. The filename numbers
are a load-order convention: each concern gets its own band, and ordering within
the pipeline is expressed by each hook's number prefix.

| Range | Purpose |
|---|---|
| `0100`-`0399` | Security: hardening (sysctl), AppArmor enforce, AnonSurf graft |
| `0400`-`0499` | Dev-stack configuration |
| `0500`-`0599` | CZD-Tools integration and the `corvid-ai-setup` AI-agent installer |
| `0600`-`0699` | Branding |

Ordering matters: hardening and tooling land before branding, and the numeric
gaps leave room to insert steps later without renumbering. Corvid's CZD-Tools hook
is `0500-czd-tools.hook.chroot`.

## Package-list split

Packages are declared in `config/package-lists/`, split by concern so each list
has a clear purpose and can be reasoned about in isolation:

| List | Contents |
|---|---|
| `base.list.chroot` | base system packages |
| `desktop.list.chroot` | KDE Plasma desktop |
| `devstack.list.chroot` | language toolchains, Docker, distrobox, editors |
| `security.list.chroot` | curated security tools (Ubuntu repos) + named Kali fallbacks |

Splitting the security list out keeps the security surface (including the few
packages that come from the pinned Kali fallback) isolated and easy to reason
about, separate from the base and desktop.

## Where each subsystem lives

```
corvid/
  SPEC.md, README.md                      spec + portfolio overview
  auto/                                    live-build config/build/clean wrappers
  provisioning/proxmox-build-vm.sh         stand up the Ubuntu 24.04 build VM
  config/
    archives/                              Kali fallback repo list + pin + GPG key
    package-lists/                         base / desktop / devstack / security
    hooks/live/                            ordered build-time config (numbered)
    includes.chroot/
      etc/sysctl.d/, etc/apparmor.d/local/ hardening drop-ins
      etc/skel/                            nvim + vscode dotfiles
      opt/czd-tools/                       CZD-Tools install/link wiring (not vendored)
    includes.binary/                       ISO boot branding
  calamares/                               installer config, LUKS FDE default
  branding/                                os-release, wallpaper, plymouth, logo
  arm64/                                   Pi 5 variant (Kali arm repo)
  docs/                                    ARCHITECTURE, BUILD, ROADMAP
```

### Branding is single-sourced

The distribution name lives in exactly one place: `branding/os-release` plus a
`CORVID_NAME` build variable. Renaming the distro is a one-line change; nothing
else hardcodes the name.

### CZD-Tools is fetched, not vendored

`config/includes.chroot/opt/czd-tools/` holds only wiring and a pointer README,
not the suite itself. The `0500-czd-tools` hook fetches the payload at build time
(clone from GitHub, or copy from a locally-staged source) and installs a `czd`
launcher plus a Plasma menu entry. The launcher is relocatable: the read-only
program sits at `/opt/czd-tools`, while per-user state lands in `~/CZD-Tools` on
first run. See `config/includes.chroot/opt/czd-tools/README.corvid.md`.

### AI-agent tooling is installed on demand, not baked in

Corvid's flagship convenience is `corvid-ai-setup`: a menu that offers to install
AI coding agents and local LLM runtimes so a user never has to hunt for the
current install command for each one. It covers Claude Code, OpenAI Codex CLI,
Google Gemini CLI, Aider, Ollama, LM Studio, and Hermes (Nous Research). The build
hook (in the `0500`-`0599` band, alongside CZD-Tools) drops the `corvid-ai-setup`
launcher on PATH and adds a Plasma menu entry; the agents and runtimes themselves
are fetched on demand when the user runs it, not preinstalled into the image. That
keeps the ISO lean and lets each agent pull its own current version at first use.
This is a feature Corvid offers its users; it is not part of how Corvid itself is
built.

### arm64 is a documented variant, not a v1.0 deliverable

The Pi 5 build reuses the same "stable base plus a pinned Kali fallback" idea, with
**Kali's** arm64 repo as the fallback source (Kali maintains strong arm64
coverage). It is intentionally kept separate so it never affects the amd64 v1.0
image. Design and config stubs are under `arm64/`.

## Security posture (v1)

Applied at build time, present on first boot:

- **AnonSurf / Tor** for system-wide anonymized routing (grafted onto the Ubuntu
  base from ParrotSec's upstream source, with its systemd unit and firewall rules
  wired explicitly).
- **LUKS full-disk encryption by default** in the Calamares installer, plus
  encrypted live persistence.
- **Hardened kernel sysctl** profile and **AppArmor in enforce mode**.

Secure Boot / MOK enrollment is deliberately **not** in v1. Only the enrollment
path is documented, in [`ROADMAP.md`](ROADMAP.md).
