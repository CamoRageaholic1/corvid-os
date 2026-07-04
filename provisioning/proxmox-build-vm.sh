#!/usr/bin/env bash
# =============================================================================
# Corvid OS -- provisioning/proxmox-build-vm.sh
# -----------------------------------------------------------------------------
# Stands up an Ubuntu 24.04 (noble) build VM on the homelab Proxmox cluster and
# installs the live-build toolchain, ready to build the Corvid amd64 ISO.
#
# APPROACH (one of two, per SPEC): we drive `qm` over SSH to a Proxmox node
# (default: pve1). We do NOT use the API token path -- the cluster API (:8006)
# is not reachable from the sandbox, whereas `ssh pve1` + `qm` is the reliable,
# already-working channel in this homelab. (If you prefer the API instead, the
# token lives in macOS Keychain:
#     security find-generic-password -a "root@pam!<token-id>" \
#         -s "proxmox-api-token" -w
#  ...but this script deliberately sticks to qm-over-SSH.)
#
# WHERE TO RUN: from macOS (uses your `ssh pve1` config/alias) OR directly on a
# pve node (set PVE_SSH_TARGET=local to skip SSH). Nothing here runs `lb`; the
# ISO build happens later, inside the VM this script creates.
#
# ASSUMPTIONS (override any via env vars, see the CONFIG block):
#   * You have SSH access to the Proxmox node as root (key-based).  [SPEC]
#   * The cluster runs Proxmox 8/9 (this uses `qm set --scsiN ...,import-from=`
#     and `qm disk resize`, which require qemu-server >= 8).
#   * Storage `local-lvm` exists for the VM disk; storage `local` has the
#     "snippets" content type enabled (Datacenter > Storage > local > Content:
#     Snippets) so cloud-init user-data can install the build deps on first
#     boot. If snippets are unavailable, the VM is still created -- just SSH in
#     afterward and run the apt-get line this script prints.
#   * VMID ${VMID} is free. The script aborts if it is already taken.
#   * You have an SSH public key at ${SSH_PUBKEY} to log into the new VM.
#
# WHAT YOU GET: a running VM (default 6 vCPU / 8 GB RAM / 80 GB disk) with
# live-build + debootstrap + qemu-utils + ISO tooling, reachable over SSH as
# user "${CI_USER}". Then, inside it:
#     git clone <this corvid repo>  &&  cd corvid
#     sudo lb config   # (auto/config runs)     -> materialise the tree
#     sudo lb build    # (auto/build runs)      -> corvid-amd64.hybrid.iso
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG -- override anything with environment variables, e.g.:
#   VMID=9001 VM_MEMORY=12288 ./provisioning/proxmox-build-vm.sh
# ----------------------------------------------------------------------------
PVE_SSH_TARGET="${PVE_SSH_TARGET:-pve1}"          # SSH target, or "local" to run on-node
VMID="${VMID:-9000}"                              # must be unused
VM_NAME="${VM_NAME:-corvid-build}"
VM_CORES="${VM_CORES:-6}"                          # SPEC: 6 cores
VM_MEMORY="${VM_MEMORY:-8192}"                     # SPEC: 8 GB RAM (MiB)
VM_DISK_GB="${VM_DISK_GB:-80}"                     # SPEC: 80 GB disk
VM_STORAGE="${VM_STORAGE:-local-lvm}"             # SPEC: local-lvm
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"        # storage that holds cloud-init snippets
SNIPPET_DIR="${SNIPPET_DIR:-/var/lib/vz/snippets}" # on-node path backing ${SNIPPET_STORAGE}

CI_USER="${CI_USER:-corvid}"
SSH_PUBKEY="${SSH_PUBKEY:-${HOME}/.ssh/id_ed25519.pub}"  # falls back to id_rsa.pub below

# Ubuntu 24.04 LTS cloud image (amd64). Fetched onto the node if not present.
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMG_PATH="${IMG_PATH:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}"

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[corvid]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[corvid][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[corvid][error]\033[0m %s\n' "$*" >&2; exit 1; }

# Run a command on the Proxmox node (directly if PVE_SSH_TARGET=local, else via SSH).
pve() {
	if [ "${PVE_SSH_TARGET}" = "local" ]; then
		"$@"
	else
		ssh -o BatchMode=yes "${PVE_SSH_TARGET}" "$@"
	fi
}

# Pipe stdin into a command on the node (used to write the snippet file).
pve_stdin() {
	if [ "${PVE_SSH_TARGET}" = "local" ]; then
		"$@"
	else
		ssh -o BatchMode=yes "${PVE_SSH_TARGET}" "$@"
	fi
}

# Fallback login setup via qm's native cloud-init (used only when the cicustom
# snippet path is unavailable). Writes the pubkey to a temp file ON THE NODE
# (so it works over SSH -- no local process substitution) and points --sshkeys
# at it. Only sets up login; build-dep install is then a manual step.
set_native_login() {
	local remote_key="/tmp/corvid-${VMID}.pub"
	if pve_stdin sh -c "cat > '${remote_key}'" <<KEYEOF
${PUBKEY_CONTENT}
KEYEOF
	then
		pve qm set "${VMID}" --ciuser "${CI_USER}" --sshkeys "${remote_key}" \
			&& log "Fallback: created login user '${CI_USER}' via qm cloud-init." \
			|| warn "Could not set --ciuser/--sshkeys; use the Proxmox console to log in."
	else
		warn "Could not stage pubkey on node; use the Proxmox console to log in."
	fi
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------
log "Preflight checks..."

# Resolve an SSH public key to inject into the VM.
if [ ! -f "${SSH_PUBKEY}" ]; then
	if [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
		SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
	else
		die "No SSH public key at ${SSH_PUBKEY} (or ~/.ssh/id_rsa.pub). Set SSH_PUBKEY=..."
	fi
fi
PUBKEY_CONTENT="$(cat "${SSH_PUBKEY}")"
log "Using SSH public key: ${SSH_PUBKEY}"

# Verify we can reach the node and that qm exists.
pve qm list >/dev/null 2>&1 || die "Cannot run 'qm' on '${PVE_SSH_TARGET}'. Check SSH access / that it is a Proxmox node."
log "Proxmox node '${PVE_SSH_TARGET}' reachable, qm present."

# Refuse to clobber an existing VMID.
if pve qm status "${VMID}" >/dev/null 2>&1; then
	die "VMID ${VMID} already exists on ${PVE_SSH_TARGET}. Set VMID=<free id>."
fi

# ----------------------------------------------------------------------------
# 1. Fetch the Ubuntu cloud image onto the node (idempotent)
# ----------------------------------------------------------------------------
log "Ensuring Ubuntu 24.04 cloud image is present at ${IMG_PATH} on the node..."
pve sh -c "test -f '${IMG_PATH}' || { mkdir -p \"\$(dirname '${IMG_PATH}')\" && wget -q -O '${IMG_PATH}' '${IMG_URL}'; }" \
	|| die "Failed to fetch cloud image ${IMG_URL}"
log "Cloud image ready."

# ----------------------------------------------------------------------------
# 2. Create + configure the VM
# ----------------------------------------------------------------------------
log "Creating VM ${VMID} (${VM_NAME}): ${VM_CORES} vCPU, ${VM_MEMORY} MiB RAM..."
pve qm create "${VMID}" \
	--name "${VM_NAME}" \
	--cores "${VM_CORES}" \
	--memory "${VM_MEMORY}" \
	--cpu host \
	--ostype l26 \
	--scsihw virtio-scsi-single \
	--net0 "virtio,bridge=${VM_BRIDGE}" \
	--agent enabled=1 \
	--serial0 socket \
	--vga serial0

# Import the cloud image as the boot disk (Proxmox 8/9 one-shot import).
log "Importing cloud image as scsi0 on ${VM_STORAGE}..."
pve qm set "${VMID}" --scsi0 "${VM_STORAGE}:0,import-from=${IMG_PATH},discard=on,ssd=1"

# Cloud-init drive + boot order.
pve qm set "${VMID}" --ide2 "${VM_STORAGE}:cloudinit"
pve qm set "${VMID}" --boot "order=scsi0"

# Grow the (small) cloud image disk to the requested size.
log "Resizing disk to ${VM_DISK_GB} GB..."
pve qm disk resize "${VMID}" scsi0 "${VM_DISK_GB}G"

# Network via cloud-init (DHCP). User + packages come from the cicustom snippet.
pve qm set "${VMID}" --ipconfig0 "ip=dhcp"

# ----------------------------------------------------------------------------
# 3. cloud-init user-data snippet: create the user + install live-build deps
# ----------------------------------------------------------------------------
SNIPPET_NAME="corvid-build-${VMID}-user.yaml"
REMOTE_SNIPPET="${SNIPPET_DIR}/${SNIPPET_NAME}"

log "Writing cloud-init user-data snippet to ${REMOTE_SNIPPET} on the node..."
# Note: heredoc is unquoted so ${CI_USER} / ${PUBKEY_CONTENT} expand locally
# before being sent to the node.
if pve_stdin sh -c "mkdir -p '${SNIPPET_DIR}' && cat > '${REMOTE_SNIPPET}'" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
users:
  - name: ${CI_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: true
    ssh_authorized_keys:
      - ${PUBKEY_CONTENT}
package_update: true
package_upgrade: false
packages:
  # --- live-build toolchain ---
  - live-build
  - debootstrap
  - ubuntu-keyring
  # --- ISO assembly + bootloaders (iso-hybrid, BIOS + UEFI) ---
  - xorriso
  - isolinux
  - syslinux
  - syslinux-common
  - syslinux-utils
  - grub-pc-bin
  - grub-efi-amd64-bin
  - mtools
  - dosfstools
  - squashfs-tools
  # --- misc build/runtime deps ---
  - qemu-utils
  - qemu-system-x86
  - rsync
  - git
  - ca-certificates
  - curl
runcmd:
  - [ touch, /var/lib/corvid-build-ready ]
  - [ sh, -c, "echo 'corvid build VM provisioned' > /etc/motd" ]
EOF
then
	log "Snippet written. Attaching via --cicustom..."
	if pve qm set "${VMID}" --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"; then
		CICUSTOM_OK=1
	else
		CICUSTOM_OK=0
		warn "Could not attach cicustom snippet (is 'Snippets' content enabled on storage '${SNIPPET_STORAGE}'?)."
		warn "VM will still boot; falling back to a login-only user, install build deps manually."
		set_native_login
	fi
else
	CICUSTOM_OK=0
	warn "Could not write snippet to ${REMOTE_SNIPPET}. VM will still boot; install deps manually."
	set_native_login
fi

# ----------------------------------------------------------------------------
# 4. Start it
# ----------------------------------------------------------------------------
log "Starting VM ${VMID}..."
pve qm start "${VMID}"

# ----------------------------------------------------------------------------
# Done -- next steps
# ----------------------------------------------------------------------------
# Show the right way to invoke qm in the hints (direct on-node vs over SSH).
if [ "${PVE_SSH_TARGET}" = "local" ]; then
	QM_HINT="qm"
else
	QM_HINT="ssh ${PVE_SSH_TARGET} qm"
fi

cat <<NEXT

$(log "VM ${VMID} (${VM_NAME}) is booting.")

Find its IP (needs the guest agent, ~30s after boot):
    ${QM_HINT} guest cmd ${VMID} network-get-interfaces
  (or check your DHCP/UniFi leases for host '${VM_NAME}')

Then SSH in as '${CI_USER}':
    ssh ${CI_USER}@<vm-ip>

Cloud-init installs the build toolchain on first boot. Confirm it finished:
    test -f /var/lib/corvid-build-ready && echo READY

If the cicustom snippet did NOT attach (CICUSTOM_OK=${CICUSTOM_OK:-0}), install the
build deps manually inside the VM:
    sudo apt-get update && sudo apt-get install -y \\
      live-build debootstrap ubuntu-keyring xorriso isolinux syslinux \\
      syslinux-common syslinux-utils grub-pc-bin grub-efi-amd64-bin mtools \\
      dosfstools squashfs-tools qemu-utils qemu-system-x86 rsync git ca-certificates

Build the ISO (inside the VM, in a checkout of this repo):
    sudo lb config      # runs auto/config
    sudo lb build       # runs auto/build -> corvid-amd64.hybrid.iso  (long!)

Smoke-test the result:
    qemu-system-x86_64 -enable-kvm -m 4096 -cdrom corvid-amd64.hybrid.iso

NEXT
