#!/bin/sh
# ============================================================================
# corvid-firstboot.sh  —  Corvid OS first-boot finalizer (Dev integration)
# ----------------------------------------------------------------------------
# Runs ONCE on the first boot of the INSTALLED/LIVE system, driven by
# corvid-firstboot.service. It finishes the Docker/rootless wiring that the
# build-time hook (0400-devstack-config) could NOT complete, because the real
# human account is created by Calamares at install time (or is the live 'corvid'
# user) — it does not exist inside the chroot when 0400 runs.
#
# What it does (all idempotent):
#   1. Ensure the 'docker' group exists.
#   2. Add every HUMAN user (UID >= 1000, real login shell, not 'nobody') to it.
#   3. Ensure /etc/subuid and /etc/subgid have non-overlapping ranges for those
#      users (needed by rootless podman / distrobox).
#   4. Enable + start docker.socket (socket activation) if the unit is present.
#   5. Disable itself so it never runs again.
#
# Failure policy: `set -e` catches real logic errors, but Docker being absent
# must NOT brick the boot — every Docker-touching step is guarded so a missing
# daemon only WARNs and we continue. Output goes to stdout/stderr, which systemd
# captures into the journal; we also mirror to `logger` under tag 'corvid-firstboot'.
# ============================================================================
set -e

TAG="corvid-firstboot"

# Log to the journal via logger when available; always echo too so `journalctl
# -u corvid-firstboot.service` (which captures unit stdout) shows everything.
log()  { echo "[${TAG}] $*"; command -v logger >/dev/null 2>&1 && logger -t "${TAG}" -p user.info  "$*" || true; }
warn() { echo "[${TAG}][WARN] $*" >&2; command -v logger >/dev/null 2>&1 && logger -t "${TAG}" -p user.warning "$*" || true; }

log "First-boot finalizer starting."

# ---------------------------------------------------------------------------
# 1. Ensure the 'docker' group exists.
# ---------------------------------------------------------------------------
# `groupadd -f` is a no-op if the group already exists (0400 usually created it),
# so this is safe to re-run. We do NOT require the docker daemon for this — the
# group is just a Unix group and membership is meaningful even before dockerd
# is installed/started.
if command -v groupadd >/dev/null 2>&1; then
    groupadd -f docker
    log "Ensured 'docker' group exists."
else
    warn "groupadd not found; cannot ensure 'docker' group. Skipping group/subid steps."
    # Nothing else here makes sense without user-management tools present.
    exit 0
fi

# ---------------------------------------------------------------------------
# Helper: enumerate human users from /etc/passwd.
# ---------------------------------------------------------------------------
# "Human" = UID >= 1000, UID < 65534 (excludes the 'nobody'/65534 sentinel), a
# real interactive login shell (not */nologin, */false, /bin/sync, or empty),
# and name not literally 'nobody'. Emits one username per line.
human_users() {
    awk -F: '
        $1 == "nobody" { next }
        {
            uid = $3 + 0
            shell = $7
            if (uid >= 1000 && uid < 65534 &&
                shell != "" &&
                shell !~ /(nologin|false|\/sync)$/) {
                print $1
            }
        }
    ' /etc/passwd
}

# ---------------------------------------------------------------------------
# Helper: ensure a subuid/subgid entry for a user in the given file.
# ---------------------------------------------------------------------------
# Rootless podman/distrobox need a delegated range of sub{u,g}ids per user. If
# the user already has a line, leave it untouched (idempotent). Otherwise
# allocate the next free 65536-wide block AFTER the highest end currently in the
# file (min base 100000), so concurrently-added users never overlap.
ensure_subid() {
    _file="$1"
    _user="$2"
    _count=65536

    [ -f "${_file}" ] || : > "${_file}"

    if grep -q "^${_user}:" "${_file}" 2>/dev/null; then
        return 0
    fi

    # Highest (start+count) already allocated in this file; default base 100000.
    _next=$(awk -F: '
        { end = $2 + $3; if (end > max) max = end }
        END { if (max < 100000) max = 100000; print max }
    ' "${_file}")

    printf '%s:%s:%s\n' "${_user}" "${_next}" "${_count}" >> "${_file}"
    log "Added ${_user} to ${_file} (${_next}:${_count})."
}

# ---------------------------------------------------------------------------
# 2 + 3. Add each human user to 'docker' and give them subuid/subgid ranges.
# ---------------------------------------------------------------------------
_found_user=0
for u in $(human_users); do
    _found_user=1

    # usermod -aG is additive and idempotent (re-adding an existing member is a
    # no-op that still returns 0). Guard so a single failure can't abort the boot.
    if usermod -aG docker "${u}" 2>/dev/null; then
        log "Ensured ${u} is in the 'docker' group."
    else
        warn "Could not add ${u} to the 'docker' group."
    fi

    ensure_subid /etc/subuid "${u}"
    ensure_subid /etc/subgid "${u}"
done

if [ "${_found_user}" -eq 0 ]; then
    warn "No human users (UID >= 1000) found at first boot; nothing to add to 'docker'."
fi

# ---------------------------------------------------------------------------
# 4. Enable + start docker.socket (socket activation), if Docker is installed.
# ---------------------------------------------------------------------------
# We deliberately target docker.socket, NOT docker.service: socket activation
# lets dockerd start on first client use instead of eagerly at boot, which is
# lighter and matches how the group membership is actually consumed. Everything
# here is optional — a build without Docker (or a failed enable) only warns.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files docker.socket >/dev/null 2>&1 \
       && systemctl list-unit-files docker.socket 2>/dev/null | grep -q '^docker\.socket'; then
        if systemctl enable --now docker.socket 2>/dev/null; then
            log "Enabled and started docker.socket."
        else
            warn "docker.socket present but could not be enabled/started; Docker may still work on next boot."
        fi
    else
        warn "docker.socket unit not found; Docker not installed? Continuing without it."
    fi
else
    warn "systemctl not available; cannot enable docker.socket. Continuing."
fi

# ---------------------------------------------------------------------------
# 5. Disable ourselves so this only ever runs once.
# ---------------------------------------------------------------------------
# Removing the multi-user.target.wants symlink is enough to prevent re-runs; we
# leave the script + unit file on disk so it can be re-triggered manually
# (`systemctl start corvid-firstboot.service`) if an admin ever wants to re-run
# the wiring. Guarded so a disable hiccup doesn't fail the boot.
if command -v systemctl >/dev/null 2>&1; then
    if systemctl disable corvid-firstboot.service 2>/dev/null; then
        log "Disabled corvid-firstboot.service (one-shot complete)."
    else
        warn "Could not disable corvid-firstboot.service; it may re-run next boot (harmless — it is idempotent)."
    fi
fi

log "First-boot finalizer complete."
exit 0
