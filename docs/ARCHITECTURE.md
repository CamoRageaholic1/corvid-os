# Corvid OS - Architecture

How the pieces fit together, and why the major choices were made. The build
specification in [`../SPEC.md`](../SPEC.md) is the source of truth; this document
explains the reasoning and the layout behind it.

## The one-sentence model

Corvid is a Kubuntu 24.04 LTS base with Parrot's security repo layered on through
strict APT pinning, assembled into a KDE Plasma live image by Debian `live-build`,
and configured by a set of ordered build hooks.

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
chroot      -->  add archives (Parrot repo + pin + key)
   |             install the package lists (base/desktop/devstack/security)
   |             run config/hooks/live/* in numeric order
   v
binary      -->  add the installer (Calamares), ISO boot branding,
   |             assemble the squashfs and bootloader
   v
corvid-amd64.iso   (~8-9 GB)
```

Two rules govern this pipeline and appear throughout the repo:

1. **APT pinning is mandatory.** The base is authoritative; Parrot is a
   low-priority add-on source. Details below.
2. **This repo holds configuration only.** No one runs `lb build` on a laptop. The
   build happens on a provisioned Proxmox VM (see [`BUILD.md`](BUILD.md)). Scripts
   are validated with `bash -n` and shellcheck, not by executing the build.

## Why Kubuntu base + Parrot pinning

The core design tension is "stable daily driver" versus "current security
toolset". Corvid resolves it by separating the two into different layers with
different update dynamics, held apart by APT pinning.

- **Base: Kubuntu 24.04 LTS (noble).** LTS gives years of support and a base that
  does not move under you. Starting from Kubuntu specifically (rather than stock
  Ubuntu plus a desktop) means Plasma is already correct, so the desktop is not a
  retrofit.
- **Tools: Parrot repo, pinned low.** Parrot is Debian-based, not Ubuntu-based, so
  its packages are close enough to install against a noble base but different
  enough that they must never be allowed to satisfy core dependencies. The pin
  (Ubuntu/noble at Pin-Priority 900+, Parrot at ~100) means Parrot packages are
  installable only when named explicitly, and can never win a version race for
  `glibc`/`libc6`, `python3`, `systemd`, or other base libraries. That single
  discipline is what keeps the LTS base from breaking. The Parrot GPG key is
  added alongside the source. This lives under `config/archives/`.

The security tools are pulled in as the **full** metapackage
(`parrot-tools-full` or equivalent). This is deliberately large, and the roughly
8 to 9 GB ISO that results is expected and accepted per the spec.

### Approaches that were rejected

- **Linux From Scratch (LFS).** Building the whole userland from source would give
  total control but throws away the entire value proposition: LTS stability,
  security updates, and a maintained package ecosystem. It would turn a
  distribution-assembly project into an indefinite maintenance burden with no
  upstream to lean on. Rejected.
- **Snaps for the toolset.** Snap packaging of security tools is sparse,
  inconsistent, and adds confinement and startup friction that fights the way
  pentest tools expect to touch the network and filesystem. The APT + pinning
  route reuses Parrot's existing, well-maintained catalog directly. Rejected in
  favor of native `.deb` packages from the pinned Parrot repo.
- **Just shipping Kali or Parrot as-is.** That would give the tools but not the
  stable LTS base, the specific dev-stack curation, or the branding and hardening
  posture Corvid defines. The point of Corvid is the combination.

## Hook numbering scheme

All build-time configuration happens through scripts in `config/hooks/live/`,
which `live-build` runs in filename order inside the chroot. The filename numbers
are a load-order convention: each concern gets its own band, and ordering within
the pipeline is expressed by each hook's number prefix.

| Range | Purpose |
|---|---|
| `0100`-`0399` | Security: hardening (sysctl), AppArmor enforce, AnonSurf graft |
| `0400`-`0499` | Dev-stack configuration |
| `0500`-`0599` | CZD-Tools integration |
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
| `security.list.chroot` | the Parrot tools metapackage |

Splitting the security metapackage into its own list keeps the "big, pinned,
comes-from-Parrot" surface isolated from the base and desktop, which come from
Ubuntu.

## Where each subsystem lives

```
corvid/
  SPEC.md, README.md                      spec + portfolio overview
  auto/                                    live-build config/build/clean wrappers
  provisioning/proxmox-build-vm.sh         stand up the Ubuntu 24.04 build VM
  config/
    archives/                              Parrot repo list + pin + GPG key
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

### arm64 is a documented variant, not a v1.0 deliverable

The Pi 5 build reuses the same "stable base plus pinned security repo" idea but
swaps Parrot for **Kali's** arm64 repo, because Parrot's arm64 coverage is thin.
It is intentionally kept separate so it never affects the amd64 v1.0 image. Design
and config stubs are under `arm64/`.

## Security posture (v1)

Applied at build time, present on first boot:

- **AnonSurf / Tor** for system-wide anonymized routing (a Parrot package grafted
  onto the Ubuntu base, with its systemd unit and firewall rules wired explicitly).
- **LUKS full-disk encryption by default** in the Calamares installer, plus
  encrypted live persistence.
- **Hardened kernel sysctl** profile and **AppArmor in enforce mode**.

Secure Boot / MOK enrollment is deliberately **not** in v1. Only the enrollment
path is documented, in [`ROADMAP.md`](ROADMAP.md).
