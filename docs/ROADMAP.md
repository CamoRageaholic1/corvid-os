# Corvid OS - Roadmap

This document covers the things Corvid **intends** to do but does not ship in
version 1.0. Everything here is a plan, not a promise made by the current ISO. It
gathers the security-DNA future work — Secure Boot / MOK and the encrypted live
persistence usage guide — alongside the pentest hardening tradeoffs note and a
summary of the arm64 / Pi 5 variant, so the whole roadmap lives in one place.

The v1.0 security features that ARE shipping (for contrast) are: AnonSurf/Tor,
a hardened kernel sysctl profile, AppArmor in enforce mode, a LUKS-by-default
installer, and encrypted live persistence support. Those are done. Everything
below is future work.

---

## 1. Secure Boot via MOK enrollment (post-v1 add-on)

**Status: DEFERRED. Not in v1. Documented here as the realistic path.**

### 1.1 What Secure Boot is, in plain terms

Secure Boot is a firmware feature on modern PCs (part of UEFI, the software
built into the motherboard that runs before your operating system). When it is
turned on, the firmware refuses to run any boot code that is not signed by a
cryptographic key the firmware already trusts. The goal is to stop "bootkits":
malware that loads before the operating system and is therefore invisible to it.

The chain looks like this:

```
UEFI firmware  ->  bootloader (shim + GRUB)  ->  Linux kernel  ->  kernel modules
   trusts a key      each stage must be signed by a key the previous stage trusts
```

If any link is unsigned or signed by an untrusted key, the firmware halts the
boot with a security violation.

### 1.2 Why full Secure Boot is effectively closed to an independent distro

The only key trusted by almost every PC out of the box is **Microsoft's**. The
firmware ships with Microsoft's certificates pre-loaded because Microsoft's
signing is what makes Windows boot. Linux distributions boot under Secure Boot
by using a small first-stage bootloader called **shim** that Microsoft has
signed. The major distros (Ubuntu, Fedora, Debian, etc.) each went through
Microsoft's signing program to get their shim signed.

For a small independent project like Corvid, that door is realistically closed:

- Getting your own shim signed by Microsoft requires an account with a hardware
  vendor identity, legal agreements, and a review process aimed at established
  vendors. It is not something a portfolio distro gets.
- You cannot legally redistribute another distro's signed shim as if it were
  yours and expect a clean chain, because the shim is tied to that distro's
  embedded vendor certificate.

So "real" Secure Boot (works on any locked-down machine with zero user action)
is not a practical v1 goal, and pretending otherwise would be dishonest. The
honest, achievable path is **MOK enrollment**, described next.

### 1.3 The realistic path: MOK (Machine Owner Key) enrollment

MOK stands for **Machine Owner Key**. It is a mechanism, built into the same
signed `shim` bootloader mentioned above, that lets the physical owner of a
machine add THEIR OWN trusted key to that one machine's firmware. Instead of
asking Microsoft to trust Corvid, we ask the person sitting at the keyboard to
trust Corvid, one time, on their own hardware.

This is the standard way NVIDIA's out-of-tree driver, VirtualBox modules, and
DKMS-built kernel modules get trusted under Secure Boot today. It is a
well-trodden path, not a hack.

The tradeoff: it requires a one-time interaction at the machine's console (a
blue MokManager screen at reboot) and a Corvid-generated key. It does not work
for a fully unattended install on a machine you cannot touch. For a pentest
distro run by its owner, that is an acceptable price.

### 1.4 Step-by-step MOK plan (what a future `bootloaders/` implementation does)

This is the build-and-runtime plan for when Secure Boot moves from roadmap to
shipped. It slots into the `config/bootloaders/` directory the SPEC reserves
(currently marked unused in v1).

**A. Generate a Corvid signing key (build host, once):**

1. Create a key pair used only for signing boot components:
   ```
   openssl req -new -x509 -newkey rsa:2048 -nodes \
     -keyout corvid-mok.key -out corvid-mok.crt \
     -days 3650 -subj "/CN=Corvid OS Secure Boot MOK/"
   ```
   `corvid-mok.key` is the private key (keep it secret, off the ISO).
   `corvid-mok.crt` is the public certificate (this is what gets enrolled).
2. Convert the certificate to the DER form MokManager expects:
   ```
   openssl x509 -in corvid-mok.crt -outform DER -out corvid-mok.cer
   ```

**B. Sign the boot chain during the build:**

3. Ship Ubuntu's already-Microsoft-signed `shim` unchanged. Shim is the piece
   that talks to the firmware and to MokManager.
4. Sign the GRUB bootloader binary and the Linux kernel with the Corvid private
   key using `sbsign`:
   ```
   sbsign --key corvid-mok.key --cert corvid-mok.crt \
     --output grubx64.efi.signed grubx64.efi
   sbsign --key corvid-mok.key --cert corvid-mok.crt \
     --output vmlinuz.signed vmlinuz
   ```
5. Place `corvid-mok.cer` (the public certificate) on the ISO so the installer
   can offer to enroll it.

**C. Enroll the key on the target machine (one-time, at the console):**

6. On first boot after install, shim detects that GRUB/kernel are signed by a
   key the firmware does not yet trust and launches **MokManager**.
7. The user chooses "Enroll MOK", selects `corvid-mok.cer`, confirms, and
   enters a one-time password they set during install.
8. The machine reboots. The Corvid key is now stored in the firmware's MOK
   list, and from then on the signed GRUB and kernel boot cleanly with Secure
   Boot ON, with no further prompts.

**D. Keep modules trusted:**

9. Sign out-of-tree kernel modules (the pentest stack pulls in a few, and the
   NVIDIA driver if used) with the same key via DKMS's built-in signing hook so
   they load under Secure Boot.

### 1.5 Acceptance criteria for the future Secure Boot milestone

- Corvid boots with Secure Boot enabled on a reference machine after a single
  MOK enrollment, with no security-violation halt.
- Kernel and GRUB report as signed (`mokutil --sb-state` shows enabled, and the
  kernel is not tainted for an unsigned module).
- The private signing key never appears on the distributed ISO.
- Documentation walks the user through the MokManager screens with screenshots.

---

## 2. arm64 / Raspberry Pi 5 variant (v1.1)

**Status: planned for v1.1. Not blocking the amd64 v1.0 ISO.** (Build config lives
in the `arm64/` directory. Summarized here so the whole roadmap lives in one
place.)

The important security-relevant fact, restated from the SPEC so it does not get
lost: the Pi 5 build does **not** use the Parrot repository. Parrot's package
repo is built for amd64 (Intel/AMD 64-bit) machines and has poor coverage for
arm64 (the 64-bit ARM architecture the Pi 5 uses). The arm64 variant therefore
sources its security tooling from **Kali Linux's arm64 repository**, which is
built and maintained for ARM boards specifically.

Consequences to plan for:

- The APT pinning file for arm64 pins Kali (not Parrot) as the low-priority
  security source, using the same "base wins, security tools pulled explicitly"
  logic the amd64 pinning uses.
- AnonSurf on arm64: Kali does not package AnonSurf. On the Pi 5 variant,
  AnonSurf comes from the git fallback path (the same ParrotSec source the
  amd64 hook 0300 already falls back to), or is replaced by a Kali-native
  transparent-Tor approach. This is an open item for the v1.1 cycle.
- Secure Boot does not apply the same way on the Pi 5; the Pi uses its own
  bootloader chain, so the MOK section above is amd64/UEFI only.

---

## 3. Encrypted live persistence (usage guide)

**Status: SUPPORTED in v1.** The boot side (the kernel boot parameters that turn
persistence on) lives in the live-build boot configuration. This section is the
USB side: how a user actually creates the encrypted persistence storage so those
boot parameters have something to find.

### 3.1 What "live persistence" means and why encrypt it

A "live" system runs entirely from the USB stick or ISO in RAM, and normally
forgets everything when you power off. **Persistence** is an optional feature of
Debian live systems (which Corvid is built on) that saves your changes (files,
installed packages, settings) onto a dedicated area of the USB so they survive
reboots.

For a pentest USB that travels in a bag, unencrypted persistence is a liability:
anyone who picks up the stick can read your loot, notes, keys, and history.
**LUKS** (Linux Unified Key Setup, the standard Linux full-disk-encryption
format) wraps that persistence area in a passphrase. Lose the stick and the data
is just noise without the passphrase.

### 3.2 How Corvid's boot side finds persistence

Debian live systems look for persistence when the kernel is booted with the
`persistence` boot parameter, and they use encrypted persistence when booted
with `persistence-encryption=luks`. These are set in the live-build boot append
line (the default kernel command line baked into the ISO's boot menu). The
mechanism, so the two sides line up:

- At boot, live-boot scans attached storage for a partition or file whose
  filesystem **label** is `persistence`.
- On that filesystem it reads a small text file named `persistence.conf` that
  says which directories to make persistent.
- With `persistence-encryption=luks`, live-boot expects that partition to be a
  LUKS container and prompts for the passphrase before mounting it.

> **Dependency note:** the exact boot parameters (`persistence` and
> `persistence-encryption=luks`) must be present in the live-build boot append
> configuration for the steps below to work. This doc assumes they are. If the
> boot line changes, keep the label and flag names in that config and this guide
> in sync. This is the one cross-cutting dependency in the persistence feature.

### 3.3 Creating an encrypted persistence partition on a USB (user steps)

These run on the Corvid live system (or any Linux) with the target USB inserted.
In this example the USB is `/dev/sdX` and already holds the Corvid live image on
its first partition. Adjust `sdX` to your actual device and be certain of it;
picking the wrong device destroys data.

1. **Make a second partition** on the USB to hold persistence, using the free
   space after the live image. With `parted`:
   ```
   sudo parted /dev/sdX --align optimal mkpart primary 100% -- -0
   ```
   (In practice use `cfdisk`/`gparted` to place a new partition after the live
   partition. Call it `/dev/sdX2` below.)

2. **Create a LUKS encrypted container** on that partition. This prompts you to
   set the passphrase that protects everything:
   ```
   sudo cryptsetup luksFormat /dev/sdX2
   ```

3. **Open (unlock) the container** so we can put a filesystem inside it:
   ```
   sudo cryptsetup luksOpen /dev/sdX2 corvid-persistence
   ```
   This creates `/dev/mapper/corvid-persistence`, an unlocked view of the
   encrypted partition.

4. **Create a filesystem inside it and give it the required label** `persistence`
   (the label is how live-boot recognizes it):
   ```
   sudo mkfs.ext4 -L persistence /dev/mapper/corvid-persistence
   ```

5. **Write the `persistence.conf` rules.** Mount the new filesystem and drop a
   one-line config telling live-boot what to persist. `/ union` means "persist
   the whole system, layered on top of the read-only live image":
   ```
   sudo mkdir -p /mnt/persistence
   sudo mount /dev/mapper/corvid-persistence /mnt/persistence
   echo "/ union" | sudo tee /mnt/persistence/persistence.conf
   ```
   For a narrower scope (only save your home directory, not system-wide
   changes), use `/home union` instead of `/ union`.

6. **Close everything cleanly:**
   ```
   sudo umount /mnt/persistence
   sudo cryptsetup luksClose corvid-persistence
   ```

7. **Boot from the USB.** Corvid's boot menu already carries the `persistence`
   and `persistence-encryption=luks` parameters (from the live-build config), so
   live-boot finds the labeled LUKS partition, prompts for your passphrase, and
   from then on your changes are saved encrypted across reboots.

### 3.4 Sanity checks and gotchas

- The filesystem label MUST be exactly `persistence`. A typo means live-boot
  silently ignores it and you get a normal amnesiac live session.
- `persistence.conf` lives at the ROOT of the persistence filesystem, not in a
  subdirectory.
- If you booted without seeing a passphrase prompt, the boot parameters are
  missing or the partition was not recognized as LUKS; recheck section 3.2.
- Persistence stores your changes in the clear inside the unlocked container
  while the session is running. LUKS protects data AT REST (powered off), not a
  running session someone is already sitting in front of.

---

## 4. Hardening tradeoffs for a pentest distro (design note)

This is the reasoning behind why Corvid is hardened the way it is, and not
harder. It exists so a reviewer understands the choices are deliberate.

A pentest distribution has a split personality. It should be **hard to attack**
(it holds an operator's access, notes, and keys, and it sits on hostile
networks) but it must NOT be **hard to attack WITH** (its entire job is to send
weird traffic, attach debuggers, sniff, spoof, and run untrusted binaries).
Generic server-hardening guides optimize only for the first half and will
quietly break the second. Corvid's security profile picks the settings that
raise the cost of attacking the box while leaving the offensive toolset intact.

Concrete examples of where Corvid deliberately stops short of "maximum":

- **ptrace scope is 1, not 2.** Level 2 would force every debugger and dynamic
  analysis tool to run as root. We accept slightly more local exposure so that
  gdb, radare2/rizin, strace, and friends work as a normal user. (See the
  sysctl profile for the full rationale.)
- **Reverse-path filtering is strict by default but documented as toggleable.**
  Strict anti-spoofing breaks on-path/MITM work (responder, bettercap, mitm6).
  We ship it on for defense and give the exact one-line command to relax it per
  engagement, rather than shipping it off.
- **IP forwarding and unprivileged user namespaces are left alone.** Locking
  them down is standard server hardening, but it would break Docker, distrobox,
  rootless containers, and MITM pivoting, all of which are core to Corvid. The
  small added surface is an accepted, documented cost.
- **No default host firewall.** A locked INPUT/OUTPUT ruleset would silently
  drop scan traffic and break listeners. Corvid installs the firewall tooling
  but enforces no ruleset; AnonSurf owns the only firewall rules, and only while
  the user has toggled it on.
- **AppArmor confines daemons, not the operator.** Enforce mode wraps system
  services (the things an attacker would pivot through) and stays out of the way
  of interactive tooling. Local overrides go in
  `/etc/apparmor.d/local/` so a tripped profile is fixed narrowly instead of
  disabled wholesale.

The through-line: every relaxation is explicit, commented at the point it is
made, and reversible with a documented command. Corvid is hardened for the
threat model of "operator's machine on a hostile network," not "locked-down
kiosk that must never run anything interesting."

---

## Maintenance

This section is upkeep work that keeps existing v1 features building over time.
Nothing here is a new feature; it is the recurring housekeeping that a layered
distro (Ubuntu LTS base + Parrot security repo + a third-party PPA) needs so the
image does not silently stop building when an upstream signing key expires or a
suite name changes. Each item below is a "when this happens, do this" note.

### M.1 Rotate the Parrot archive signing key before it expires

**Why this matters, in plain terms:** APT (the package manager) only trusts a
repository if the repository's release files are signed by a GPG key APT already
holds. Corvid ships the Parrot archive key (in `config/archives/`) so the pinned
Parrot security packages install without "the following signatures were invalid"
errors. GPG keys carry an **expiry date**. Once the key expires, APT rejects the
Parrot repo and every `parrot-tools-*` install (and therefore `lb build`) fails
with an `EXPKEYSIG` / "key has expired" error, even though nothing else changed.

**The key we currently trust:**

- Fingerprint: `B711 8223 4655 2E4D 92DA 02DF 7A82 86AF 0E81 EE4A`
- Expiry to watch: **2028-11-03**

**What to do (well before that date, treat ~2028-08 as the trigger):**

1. Confirm the fingerprint and expiry of the key Corvid currently ships:
   ```
   gpg --show-keys --with-fingerprint config/archives/parrot.key.chroot
   ```
   (Substitute the actual filename used for the Parrot key in
   `config/archives/`.) Verify the fingerprint matches the one above before
   trusting anything you fetch.
2. Obtain the refreshed/rotated Parrot archive key from Parrot's official
   channel and verify its fingerprint out-of-band. Do **not** blindly replace
   the file with whatever a mirror serves. If Parrot rotates to a NEW key with a
   new fingerprint, record the new fingerprint here in this doc so the next
   maintainer can verify against it.
3. Replace the key file in `config/archives/` (same filename already wired into
   the pinning setup so no other file needs editing), commit it, and note the new
   expiry date in this section.
4. Rebuild on the Proxmox VM and confirm `apt-get update` inside the chroot shows
   no `EXPKEYSIG`/expired-key warning for the Parrot repo.

> Note: the Parrot key + pinning live in `config/archives/`. This section is the
> procedure; the actual key swap is a change to that directory.

### M.2 The mozillateam PPA key may also rotate

**Why this matters:** Corvid also trusts the **mozillateam** PPA key, staged at
`config/archives/mozillateam.key.chroot`. A PPA (Personal Package Archive) is a
third-party Ubuntu repo; this one is the standard source for a non-Snap Firefox
(and related Mozilla builds) on the Ubuntu base. Like the Parrot key, this PPA
key can be rotated or expire upstream, and when it does, APT refuses the PPA and
any package pulled from it fails to install during the build.

**How to refresh `config/archives/mozillateam.key.chroot`:**

1. Fetch the current mozillateam PPA signing key from the Ubuntu keyserver by its
   key ID (the PPA page on Launchpad lists the fingerprint; verify it matches
   what you fetch):
   ```
   gpg --keyserver keyserver.ubuntu.com --recv-keys <MOZILLATEAM_KEY_ID>
   gpg --export --armor <MOZILLATEAM_KEY_ID> > config/archives/mozillateam.key.chroot
   ```
   The `--armor` form produces the ASCII-armored `.key` text live-build expects
   in `config/archives/`.
2. Confirm the exported file's fingerprint before committing:
   ```
   gpg --show-keys --with-fingerprint config/archives/mozillateam.key.chroot
   ```
3. Keep the filename exactly `mozillateam.key.chroot` so the matching
   `mozillateam.list.chroot` sources file keeps working with no other edits.
4. Commit and rebuild; verify the mozillateam PPA updates cleanly with no
   expired/invalid-signature warning.

> Same caveat as M.1: this lives under `config/archives/`. This documents the
> refresh procedure; the file swap itself is a change to that directory.

### M.3 Re-pin review when Parrot moves its suite from `lory` to `echo`

**Why this matters:** APT pinning (the mandatory rule in SPEC section 4) pins the
Parrot repo LOW and the Ubuntu LTS base HIGH so only explicitly requested
security tools come from Parrot and core libraries (`glibc`/`libc6`/`python3`)
always come from the fixed LTS base. That pinning is written against a specific
Parrot **suite name**. Parrot's current stable suite is **`lory`** (Parrot 6,
based on Debian 12 "bookworm"). Parrot's next stable is **`echo`** (Parrot 7,
based on Debian 13 "trixie").

The risk on that move: Debian trixie ships a **newer glibc** than bookworm, and
newer still than what Ubuntu 24.04 LTS ("noble") carries. The wider the glibc gap
between the Parrot suite and the fixed Ubuntu base, the more likely a Parrot tool
pulls a libc dependency the base cannot satisfy, and the more load the pinning
has to carry to keep the base's core libraries winning. In short: **glibc skew
widens when the suite moves `lory` -> `echo`,** so the pinning needs a fresh
review, not a blind suite-name bump.

**What to do when Parrot promotes `echo` to stable:**

1. Do **not** just rename `lory` to `echo` in `config/archives/parrot.list.*`.
   Treat it as a re-pin review.
2. In `config/archives/parrot.pref.*`, re-confirm the base (noble) still holds
   Pin-Priority 900+ and Parrot stays low (~100), and specifically verify that
   `glibc`/`libc6`/`libc-bin`/`python3` and other core libs still resolve to the
   Ubuntu base, never to `echo`. Consider an explicit high-priority pin that
   nails the core libc packages to the Ubuntu origin as an extra guard.
3. Do a test build on the Proxmox VM and inspect the chroot: check `apt-cache
   policy libc6 python3` shows the Ubuntu origin winning, and that
   `parrot-tools-full` still resolves against the pinned base without dragging in
   a trixie-era libc.
4. Only after that review passes do you update the suite name and record the move
   (and the reviewed pin priorities) here.

> Note: `config/archives/parrot.list` + `parrot.pref` hold the suite name and pin
> priorities. This is the review checklist to run when Parrot 7 / `echo` lands;
> the pin edits are changes to those files.
