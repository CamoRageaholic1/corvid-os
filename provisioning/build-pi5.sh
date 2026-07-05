#!/usr/bin/env bash
# =============================================================================
# Corvid OS -- provisioning/build-pi5.sh
# -----------------------------------------------------------------------------
# Builds the Corvid OS Raspberry Pi 5 (arm64) flashable image using "Path B"
# from arm64/README.md: take Canonical's OFFICIAL Ubuntu 24.04 (noble) arm64
# preinstalled Pi image and CUSTOMIZE it in a chroot, then repackage as a
# compressed .img.xz. This reuses the Pi's known-good boot chain (firmware +
# kernel + initramfs) instead of trying to bootstrap arm64 from scratch.
#
# The build HOST is x86_64 Linux with the arm64 binfmt handler already
# registered (qemu-user-static), so `chroot` into the arm64 rootfs transparently
# runs aarch64 binaries via /usr/bin/qemu-aarch64-static.
#
# PARTITION LAYOUT (Canonical Ubuntu Pi preinstalled image, MBR / msdos):
#   * partition 1 = FAT firmware/boot -> mounted at /boot/firmware
#   * partition 2 = ext4 root
# These numbers are assumed throughout (see step 3/4). If Canonical ever changes
# the layout, adjust PART_BOOT_NUM / PART_ROOT_NUM below.
#
# USAGE:
#   sudo provisioning/build-pi5.sh [INPUT.img.xz] [OUTPUT.img.xz]
#     $1 INPUT  (default: ~/pi-build/ubuntu-pi.img.xz)   Canonical arm64 image
#     $2 OUTPUT (default: ~/pi-build/corvid-pi5-arm64.img.xz)
#
# WHAT IT DOES NOT DO: it does NOT create a user or password. Ubuntu's stock
# first-boot flow (cloud-init / console-conf) is left intact so the end user
# creates their own account on first boot of the Pi.
#
# Run as root (loop devices, bind mounts and chroot all require it).
# =============================================================================
set -euo pipefail

# --- pretty logging ----------------------------------------------------------
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'W: %s\n'  "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # provisioning/
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"                      # repo root

WORK="${CORVID_PI_WORK:-$HOME/pi-build}"
INPUT="${1:-$WORK/ubuntu-pi.img.xz}"
OUTPUT="${2:-$WORK/corvid-pi5-arm64.img.xz}"

IMG="$WORK/ubuntu-pi.img"          # decompressed working image
ROOT="$WORK/rootmnt"               # mountpoint for the root (p2) filesystem

PART_BOOT_NUM=1                    # FAT firmware/boot partition
PART_ROOT_NUM=2                    # ext4 root partition
GROW_BYTES="+8G"                   # headroom added before installing KDE + tools

# --- globals the cleanup trap references (declared so `set -u` is happy) ------
LOOP=""
PART_ROOT=""
PART_BOOT=""

# =============================================================================
# 0. Preconditions: root + every external tool present up front
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "must run as root (loop mounts + chroot). Try: sudo $0"

# xz provides both `xz` and `unxz`; guard the ones we call by name.
REQUIRED_TOOLS=(losetup parted e2fsck resize2fs mkfs.vfat xz unxz rsync chroot \
                truncate mount umount qemu-aarch64-static)
missing=()
for t in "${REQUIRED_TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
# Partition rescan: EITHER kpartx OR partprobe is acceptable.
if ! command -v kpartx >/dev/null 2>&1 && ! command -v partprobe >/dev/null 2>&1; then
    missing+=("kpartx-or-partprobe")
fi
# A sha256 tool for the sidecar (sha256sum preferred, shasum fallback).
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
else
    missing+=("sha256sum-or-shasum")
fi
[ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"

QEMU_BIN="$(command -v qemu-aarch64-static)"

# =============================================================================
# Cleanup trap: unmount everything (reverse order) + detach the loop device.
# Runs on EXIT (covers ERR via errexit) and on INT/TERM. Idempotent + defensive.
# =============================================================================
unmount_all() {
    [ -n "${ROOT:-}" ] || return 0
    # reverse of the mount order: boot/firmware, sys, proc, dev/pts, dev, root
    mountpoint -q "$ROOT/boot/firmware" 2>/dev/null && umount "$ROOT/boot/firmware" 2>/dev/null || true
    local m
    for m in sys proc dev/pts dev; do
        mountpoint -q "$ROOT/$m" 2>/dev/null && umount "$ROOT/$m" 2>/dev/null || true
    done
    mountpoint -q "$ROOT" 2>/dev/null && umount "$ROOT" 2>/dev/null || true
    return 0
}

detach_loop() {
    [ -n "${LOOP:-}" ] || return 0
    # If kpartx created /dev/mapper nodes, tear those down first.
    case "${PART_ROOT:-}" in
        /dev/mapper/*) command -v kpartx >/dev/null 2>&1 && kpartx -d "$LOOP" 2>/dev/null || true ;;
    esac
    losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
    return 0
}

cleanup() {
    local rc=$?
    set +e
    sync 2>/dev/null || true
    unmount_all
    detach_loop
    return "$rc"
}
trap cleanup EXIT INT TERM

# =============================================================================
# Helpers: attach the loop device + resolve p1/p2 partition nodes robustly.
# `losetup -fP` asks the kernel to scan partitions; on some hosts the pN nodes
# take a moment (or need partprobe/kpartx). We poll, then fall back to kpartx.
# =============================================================================
attach_loop() {
    LOOP="$(losetup -fP --show "$IMG")" || die "losetup failed for $IMG"
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -e "${LOOP}p${PART_ROOT_NUM}" ] && break
        command -v partprobe >/dev/null 2>&1 && partprobe "$LOOP" 2>/dev/null || true
        if [ ! -e "${LOOP}p${PART_ROOT_NUM}" ] && command -v kpartx >/dev/null 2>&1; then
            kpartx -a "$LOOP" 2>/dev/null || true
        fi
        sleep 1
    done
}

resolve_parts() {
    local base; base="$(basename "$LOOP")"
    if [ -e "${LOOP}p${PART_ROOT_NUM}" ]; then
        PART_ROOT="${LOOP}p${PART_ROOT_NUM}"
        PART_BOOT="${LOOP}p${PART_BOOT_NUM}"
    elif [ -e "/dev/mapper/${base}p${PART_ROOT_NUM}" ]; then
        PART_ROOT="/dev/mapper/${base}p${PART_ROOT_NUM}"
        PART_BOOT="/dev/mapper/${base}p${PART_BOOT_NUM}"
    else
        die "could not find partition nodes for $LOOP (p${PART_BOOT_NUM}/p${PART_ROOT_NUM})"
    fi
}

# e2fsck exits 1/2 when it FIXED errors -- that is success for us. >=4 is a real
# problem. Never let it abort under errexit.
run_e2fsck() {
    local dev="$1" rc=0
    e2fsck -fy "$dev" || rc=$?
    if [ "$rc" -le 2 ]; then return 0; fi
    warn "e2fsck on $dev returned $rc (uncorrected errors)"
    return 1
}

# =============================================================================
# 1. Resolve inputs + prepare WORK dir
# =============================================================================
log "Corvid OS Pi 5 build"
log "  repo root : $REPO_ROOT"
log "  work dir  : $WORK"
log "  input     : $INPUT"
log "  output    : $OUTPUT"
mkdir -p "$WORK" "$ROOT"
[ -f "$INPUT" ] || die "input image not found: $INPUT"

# =============================================================================
# 2. Decompress the input to the working image (keep the original .xz).
#    `unxz -c` writes to our chosen path and implicitly keeps the source.
# =============================================================================
log "Decompressing input -> $IMG"
rm -f "$IMG"
case "$INPUT" in
    *.xz) unxz -c "$INPUT" > "$IMG" ;;
    *.img) cp -f "$INPUT" "$IMG" ;;      # already a raw image
    *)     unxz -c "$INPUT" > "$IMG" ;;  # assume xz-compressed
esac
[ -s "$IMG" ] || die "decompressed image is empty: $IMG"

# =============================================================================
# 3. Grow the image + root partition, then grow the ext4 filesystem.
#    (a) append headroom to the image file, (b) extend partition 2 to 100%
#    on the FILE, (c) loop-attach and e2fsck + resize2fs the root fs.
# =============================================================================
log "Growing image file by $GROW_BYTES"
truncate -s "$GROW_BYTES" "$IMG"

log "Extending partition $PART_ROOT_NUM to 100% (parted, on the image file)"
# MBR/msdos table on the Pi image => no secondary-GPT fixup prompt. Script mode.
parted -s "$IMG" resizepart "$PART_ROOT_NUM" 100% \
    || die "parted resizepart failed"

log "Attaching loop device + resolving partitions"
attach_loop
resolve_parts
log "  loop=$LOOP  root=$PART_ROOT  boot=$PART_BOOT"

log "Checking + growing root filesystem"
run_e2fsck "$PART_ROOT" || die "root fs check failed before grow"
resize2fs "$PART_ROOT" || die "resize2fs grow failed"

# =============================================================================
# 4. Mount the rootfs + boot partition, bind system dirs, stage qemu + resolv.
# =============================================================================
log "Mounting root ($PART_ROOT) at $ROOT"
mount "$PART_ROOT" "$ROOT"

log "Mounting boot/firmware ($PART_BOOT) at $ROOT/boot/firmware"
mkdir -p "$ROOT/boot/firmware"
mount "$PART_BOOT" "$ROOT/boot/firmware"

log "Bind-mounting /dev /dev/pts /proc /sys"
mount --bind /dev     "$ROOT/dev"
mkdir -p "$ROOT/dev/pts"
mount --bind /dev/pts "$ROOT/dev/pts"
mount --bind /proc    "$ROOT/proc"
mount --bind /sys     "$ROOT/sys"

log "Installing qemu-aarch64-static into the rootfs"
install -D -m 0755 "$QEMU_BIN" "$ROOT/usr/bin/qemu-aarch64-static"

log "Setting a working resolv.conf inside the rootfs (backing up the original)"
if [ -e "$ROOT/etc/resolv.conf" ] || [ -L "$ROOT/etc/resolv.conf" ]; then
    mv -f "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.corvid-bak"
fi
printf 'nameserver 1.1.1.1\n' > "$ROOT/etc/resolv.conf"

# =============================================================================
# 5. Stage Corvid assets into the rootfs.
# =============================================================================
log "Generating branding assets on the host (branding/generate-assets.sh)"
if [ -x "$REPO_ROOT/branding/generate-assets.sh" ]; then
    bash "$REPO_ROOT/branding/generate-assets.sh" || warn "generate-assets.sh returned nonzero; continuing"
else
    warn "branding/generate-assets.sh not found/executable; skipping asset generation"
fi

log "Rsyncing config/includes.chroot/ into the rootfs"
if [ -d "$REPO_ROOT/config/includes.chroot" ]; then
    rsync -a "$REPO_ROOT/config/includes.chroot/" "$ROOT/"
else
    warn "config/includes.chroot missing; nothing to overlay"
fi

log "Staging chroot hooks -> /tmp/corvid-hooks"
mkdir -p "$ROOT/tmp/corvid-hooks"
if compgen -G "$REPO_ROOT/config/hooks/*.chroot" >/dev/null; then
    cp -f "$REPO_ROOT"/config/hooks/*.chroot "$ROOT/tmp/corvid-hooks/"
    chmod 0755 "$ROOT"/tmp/corvid-hooks/*.chroot 2>/dev/null || true
else
    warn "no config/hooks/*.chroot found"
fi

log "Staging Pi package lists -> /tmp/corvid-pkgs"
mkdir -p "$ROOT/tmp/corvid-pkgs"
if compgen -G "$REPO_ROOT/config-pi5/package-lists/*.list" >/dev/null; then
    cp -f "$REPO_ROOT"/config-pi5/package-lists/*.list "$ROOT/tmp/corvid-pkgs/"
else
    # Tolerate absent Pi lists: fall back to a minimal built-in list.
    warn "config-pi5/package-lists/*.list absent; using minimal fallback (kubuntu-desktop)"
    printf '%s\n' 'kubuntu-desktop' > "$ROOT/tmp/corvid-pkgs/fallback.list"
fi

# =============================================================================
# 6. Chroot customization script. Written to /tmp inside the rootfs, then run
#    via qemu-emulated bash. The script deliberately does NOT `set -e`: a single
#    arm64-missing package or a flaky hook must never abort the whole build.
# =============================================================================
log "Writing chroot customization script"
cat > "$ROOT/tmp/corvid-chroot.sh" <<'CORVID_CHROOT'
#!/bin/bash
# Runs INSIDE the arm64 rootfs (via qemu-aarch64-static). Non-fatal by design.
set -u
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o APT::Install-Recommends=false -o DPkg::Lock::Timeout=600"

: > /tmp/corvid-missing.txt
: > /tmp/corvid-hook.log

# ---- prevent service starts during the emulated install --------------------
# Under qemu-user-static there is no running init, so package postinsts that
# call systemctl/invoke-rc.d to start a daemon fail, which can abort the bulk
# apt install. policy-rc.d returning 101 makes maintainer scripts skip service
# starts during the build; services start normally on the real Pi at first boot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

# ---- ensure noble-updates is enabled ---------------------------------------
# Canonical's preinstalled Pi image ships with only the `noble` and
# `noble-security` suites, not `noble-updates`. That leaves -dev/tool packages
# pinned to their release versions while their shared libraries pick up
# -security bumps, which produces unmet exact-version dependencies (libgmp10,
# zlib1g, polkitd, plymouth, ...). Adding noble-updates keeps them aligned.
echo "==> [chroot] ensuring the noble-updates apt suite is enabled"
if ! grep -rhq 'noble-updates' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse" \
        > /etc/apt/sources.list.d/corvid-noble-updates.list
    echo "==> [chroot] added noble-updates source"
fi

echo "==> [chroot] apt-get update"
$APT update || echo "W: [chroot] apt-get update returned nonzero (continuing)"

# ---- collect package names from every staged list --------------------------
# Strip full-line '#' comments (allowing leading whitespace) and blank lines.
PKG_TMP=/tmp/corvid-pkglist.txt
: > "$PKG_TMP"
for f in /tmp/corvid-pkgs/*.list; do
    [ -e "$f" ] || continue
    awk '{ sub(/^[ \t]+/,""); sub(/[ \t]+$/,"") } /^#/ { next } /^$/ { next } { print }' "$f" >> "$PKG_TMP"
done
# Always guarantee the desktop + display manager, even with no desktop list.
printf '%s\n' kubuntu-desktop sddm >> "$PKG_TMP"
PKGS="$(sort -u "$PKG_TMP" | tr '\n' ' ')"
echo "==> [chroot] $(printf '%s\n' $PKGS | grep -c .) packages queued for install"

# ---- install: one bulk attempt, else fall back to one-at-a-time ------------
echo "==> [chroot] installing packages (bulk attempt)"
if $APT install -y $PKGS; then
    echo "==> [chroot] bulk install OK"
else
    echo "W: [chroot] bulk install failed; installing one at a time"
    for p in $PKGS; do
        if $APT install -y "$p"; then
            echo "  ok:   $p"
        else
            echo "  FAIL: $p"
            echo "$p" >> /tmp/corvid-missing.txt
        fi
    done
fi

# ---- enable the display manager --------------------------------------------
echo "==> [chroot] enabling sddm"
if command -v systemctl >/dev/null 2>&1 && systemctl enable sddm >/dev/null 2>&1; then
    echo "  sddm enabled via systemctl"
elif [ -e /lib/systemd/system/sddm.service ] || [ -e /usr/lib/systemd/system/sddm.service ]; then
    SDDM_UNIT=/lib/systemd/system/sddm.service
    [ -e "$SDDM_UNIT" ] || SDDM_UNIT=/usr/lib/systemd/system/sddm.service
    ln -sf "$SDDM_UNIT" /etc/systemd/system/display-manager.service \
        && echo "  sddm enabled via display-manager.service symlink" \
        || echo "W: could not enable sddm"
else
    echo "W: sddm.service not found; is sddm installed?"
fi

# ---- run staged hooks in sorted (numeric) order, non-fatal -----------------
echo "==> [chroot] running Corvid hooks"
if ls /tmp/corvid-hooks/*.chroot >/dev/null 2>&1; then
    for h in $(ls /tmp/corvid-hooks/*.chroot | sort); do
        {
            echo "======================================================"
            echo "== hook: $(basename "$h")  ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
            echo "======================================================"
        } >> /tmp/corvid-hook.log
        if /bin/sh "$h" >> /tmp/corvid-hook.log 2>&1; then
            echo "  OK:   $(basename "$h")"
        else
            echo "  FAIL: $(basename "$h")  (see /tmp/corvid-hook.log)"
        fi
    done
else
    echo "  (no hooks staged)"
fi

# ---- identity: hostname + hosts --------------------------------------------
echo "==> [chroot] setting hostname to 'corvid'"
echo corvid > /etc/hostname
if [ -f /etc/hosts ]; then
    if grep -qE '^[[:space:]]*127\.0\.1\.1' /etc/hosts; then
        sed -i -E 's/^[[:space:]]*127\.0\.1\.1.*/127.0.1.1\tcorvid/' /etc/hosts
    else
        printf '127.0.1.1\tcorvid\n' >> /etc/hosts
    fi
    grep -qE '^[[:space:]]*127\.0\.0\.1' /etc/hosts || printf '127.0.0.1\tlocalhost\n' >> /etc/hosts
else
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tcorvid\n' > /etc/hosts
fi

# ---- first-boot: LEAVE STOCK ------------------------------------------------
# Ubuntu's preinstalled Pi image ships cloud-init / console-conf so the end user
# creates their own account on first boot. We intentionally do NOT create a user
# or set a password here.
echo "==> [chroot] leaving Ubuntu's stock first-boot user setup intact"

# ---- inside-chroot cleanup (host finishes the rest after we return) --------
echo "==> [chroot] apt-get clean + prune caches/logs"
rm -f /usr/sbin/policy-rc.d
$APT clean || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
: > /etc/machine-id 2>/dev/null || truncate -s 0 /etc/machine-id 2>/dev/null || true
[ -e /var/lib/dbus/machine-id ] && rm -f /var/lib/dbus/machine-id

echo "==> [chroot] customization complete"
exit 0
CORVID_CHROOT
chmod 0755 "$ROOT/tmp/corvid-chroot.sh"

log "Entering chroot (arm64 via qemu) for customization"
chroot "$ROOT" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    /bin/bash /tmp/corvid-chroot.sh \
    || warn "chroot customization returned nonzero (see logs); continuing to finalize"

# =============================================================================
# 7. Finish cleanup: copy operator logs OUT, purge /tmp/corvid-*, remove qemu,
#    restore resolv.conf. (machine-id / var/log / apt lists were cleared inside.)
# =============================================================================
log "Copying operator logs out to $WORK"
cp -f "$ROOT/tmp/corvid-missing.txt" "$WORK/corvid-missing.txt" 2>/dev/null || true
cp -f "$ROOT/tmp/corvid-hook.log"    "$WORK/corvid-hook.log"    2>/dev/null || true
if [ -s "$WORK/corvid-missing.txt" ]; then
    warn "some packages could not be installed (arm64 gaps) -> $WORK/corvid-missing.txt"
fi

log "Removing staged build artifacts from the rootfs (/tmp/corvid-*)"
rm -rf "$ROOT"/tmp/corvid-* 2>/dev/null || true

log "Removing qemu-aarch64-static from the rootfs"
rm -f "$ROOT/usr/bin/qemu-aarch64-static"

log "Restoring original resolv.conf"
rm -f "$ROOT/etc/resolv.conf"
if [ -e "$ROOT/etc/resolv.conf.corvid-bak" ] || [ -L "$ROOT/etc/resolv.conf.corvid-bak" ]; then
    mv -f "$ROOT/etc/resolv.conf.corvid-bak" "$ROOT/etc/resolv.conf"
fi

# =============================================================================
# 8. Unmount (reverse), fsck, OPTIONAL shrink, compress, checksum.
# =============================================================================
log "Unmounting filesystems (reverse order); keeping loop attached for fsck"
sync
unmount_all

log "Final filesystem check on $PART_ROOT"
run_e2fsck "$PART_ROOT" || warn "final e2fsck reported uncorrected issues"

# ---- OPTIONAL shrink --------------------------------------------------------
# Shrink the ext4 fs to (near) minimum, then the partition, then truncate the
# image, so the artifact is small. Wrapped so ANY failure leaves the (valid,
# grown) image intact -- we never truncate unless every measurement succeeded.
attempt_shrink() {
    command -v dumpe2fs >/dev/null 2>&1 || { warn "dumpe2fs absent; skipping shrink"; return 1; }

    log "  shrink: e2fsck + resize2fs -M (minimize root fs)"
    run_e2fsck "$PART_ROOT" || return 1
    resize2fs -M "$PART_ROOT" || return 1

    # Read the now-minimized fs geometry (loop still attached).
    local info blocks bsize
    info="$(dumpe2fs -h "$PART_ROOT" 2>/dev/null)" || return 1
    blocks="$(printf '%s\n' "$info" | awk -F: '/^Block count:/ {gsub(/[[:space:]]/,"",$2); print $2}')"
    bsize="$( printf '%s\n' "$info" | awk -F: '/^Block size:/  {gsub(/[[:space:]]/,"",$2); print $2}')"
    case "$blocks" in ''|*[!0-9]*) warn "shrink: bad block count"; return 1 ;; esac
    case "$bsize"  in ''|*[!0-9]*) warn "shrink: bad block size";  return 1 ;; esac

    # fs size in 512-byte sectors, plus ~16 MiB slack so the partition >= fs.
    local fs_sectors slack_sectors part_sectors
    fs_sectors=$(( blocks * bsize / 512 ))
    slack_sectors=$(( 16 * 1024 * 1024 / 512 ))          # 32768
    part_sectors=$(( fs_sectors + slack_sectors ))

    # Partition start sector (machine-readable parted output on the image FILE).
    detach_loop
    local start end
    start="$(parted -sm "$IMG" unit s print 2>/dev/null \
             | awk -F: -v n="${PART_ROOT_NUM}:" '$0 ~ "^"n {gsub(/s/,"",$2); print $2; exit}')"
    case "$start" in ''|*[!0-9]*) warn "shrink: could not read partition start"; return 1 ;; esac
    end=$(( start + part_sectors - 1 ))
    [ "$end" -gt "$start" ] || { warn "shrink: computed end <= start"; return 1; }

    log "  shrink: resizing partition $PART_ROOT_NUM to end sector ${end}s"
    parted -s "$IMG" resizepart "$PART_ROOT_NUM" "${end}s" || return 1

    # Truncate the image just past the partition end (+1 MiB backup slack).
    local new_bytes
    new_bytes=$(( (end + 1) * 512 + 1024 * 1024 ))
    log "  shrink: truncating image to $new_bytes bytes"
    truncate -s "$new_bytes" "$IMG" || return 1

    # Re-attach + verify the shrunken fs (best effort).
    attach_loop
    resolve_parts
    run_e2fsck "$PART_ROOT" || warn "shrink: post-shrink e2fsck reported issues"
    detach_loop
    return 0
}

log "Attempting optional image shrink"
if attempt_shrink; then
    log "Shrink succeeded"
else
    warn "Shrink skipped/failed; keeping full-size (grown) image -- artifact is still valid"
fi

# Ensure the loop is detached before compressing.
detach_loop

# ---- compress ---------------------------------------------------------------
log "Compressing image -> $OUTPUT (xz -T0 -6)"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
xz -T0 -6 -c "$IMG" > "$OUTPUT" || die "xz compression failed"

# ---- checksum ---------------------------------------------------------------
log "Writing sha256 sidecar"
( cd "$(dirname "$OUTPUT")" && $SHA_CMD "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" ) \
    || die "checksum failed"

# =============================================================================
# Done. Report.
# =============================================================================
FINAL_SIZE="$(du -h "$OUTPUT" | cut -f1)"
FINAL_SHA="$(awk '{print $1}' "$OUTPUT.sha256")"
echo
log "BUILD COMPLETE"
log "  artifact : $OUTPUT"
log "  size     : $FINAL_SIZE"
log "  sha256   : $FINAL_SHA"
log "  sha file : $OUTPUT.sha256"
[ -s "$WORK/corvid-missing.txt" ] && log "  missing pkgs log : $WORK/corvid-missing.txt"
[ -s "$WORK/corvid-hook.log" ]    && log "  hook log         : $WORK/corvid-hook.log"

exit 0
