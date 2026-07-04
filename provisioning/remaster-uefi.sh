#!/bin/sh
# Corvid OS -- provisioning/remaster-uefi.sh
# ===========================================================================
# Builds a UEFI-bootable Corvid ISO. Called by auto/build.
#
#   Usage: provisioning/remaster-uefi.sh [binary-tree-or-input.iso] [output.iso]
#     default input:  binary/   (live-build's staged tree)
#     default output: corvid-amd64.iso
#
# Why build from the tree: Ubuntu's live-build 3.0 ISO step is broken three ways
# for this image -- it writes no El Torito boot record, calls a missing isohybrid,
# and its genisoimage caps files at 4 GiB (our squashfs is larger). So auto/build
# skips it and we master the ISO ourselves with `xorriso -iso-level 3`, which has
# native multi-extent >4 GiB support, in a single authoritative pass:
#   * bake a standalone GRUB x86_64-efi image whose config finds the ISO (by
#     /LIVEDIR/filesystem.squashfs) and boots the detected kernel + initrd (casper);
#   * wrap it in a FAT EFI System Partition;
#   * append that ESP and register it as the El Torito EFI boot entry.
# Result is UEFI-only, which Ventoy + modern hardware boot fine.
#
# Also supports a legacy "input is an existing ISO" mode (adds a UEFI boot record
# to a small ISO), used only if given an .iso path instead of the tree.
#
# Requires: grub-common (grub-mkstandalone), grub-efi-amd64-bin, dosfstools
# (mkfs.vfat), mtools (mmd/mcopy), xorriso.
# ===========================================================================
set -e

IN="${1:-binary}"
OUT="${2:-corvid-amd64.iso}"

for _t in grub-mkstandalone mkfs.vfat mmd mcopy xorriso; do
	command -v "$_t" >/dev/null 2>&1 || { echo "remaster-uefi: missing tool '$_t'" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---- locate the live dir + kernel/initrd (works for a tree or a mounted ISO) --
# In tree mode paths are relative to $IN; we compute paths relative to the ISO root.
find_live() {
	# $1 = root dir to inspect
	_root="$1"
	if [ -e "$_root/casper/filesystem.squashfs" ]; then LIVEDIR=casper; BOOTMODE=casper
	elif [ -e "$_root/live/filesystem.squashfs" ]; then LIVEDIR=live; BOOTMODE=live
	else echo "remaster-uefi: no filesystem.squashfs under casper/ or live/ in $_root" >&2; exit 1; fi
	KREL=$(cd "$_root" && ls "$LIVEDIR"/vmlinuz* 2>/dev/null | head -1)
	IREL=$(cd "$_root" && ls "$LIVEDIR"/initrd* 2>/dev/null | head -1)
	[ -n "$KREL" ] && [ -n "$IREL" ] || { echo "remaster-uefi: kernel/initrd not found under $_root/$LIVEDIR" >&2; exit 1; }
}

build_efi_image() {
	# baked-in GRUB config: find the ISO, boot the detected casper kernel+initrd
	cat > "$WORK/embed.cfg" <<EOF
insmod all_video
insmod iso9660
insmod part_gpt
insmod part_msdos
insmod fat
insmod search
insmod search_fs_file
insmod linux
insmod gzio
insmod normal
insmod configfile
insmod gfxterm

search --no-floppy --set=root --file /$LIVEDIR/filesystem.squashfs
if [ -z "\$root" ]; then search --no-floppy --set=root --file /.disk/info; fi

set default=0
set timeout=5
menuentry "Corvid OS (live)" {
    linux (\$root)/$KREL boot=$BOOTMODE quiet splash ---
    initrd (\$root)/$IREL
}
menuentry "Corvid OS (safe graphics)" {
    linux (\$root)/$KREL boot=$BOOTMODE nomodeset ---
    initrd (\$root)/$IREL
}
EOF
	grub-mkstandalone -O x86_64-efi -o "$WORK/BOOTX64.EFI" \
		"boot/grub/grub.cfg=$WORK/embed.cfg" \
		--modules="part_gpt part_msdos fat iso9660 search search_fs_file normal configfile linux gzio ls echo test all_video gfxterm"
	dd if=/dev/zero of="$WORK/efi.img" bs=1M count=12 status=none
	mkfs.vfat -n CORVIDEFI "$WORK/efi.img" >/dev/null
	mmd -i "$WORK/efi.img" ::/EFI ::/EFI/BOOT
	mcopy -i "$WORK/efi.img" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
}

if [ -d "$IN" ]; then
	# ================= TREE MODE (default): master the ISO from binary/ =========
	echo "==> remaster-uefi: TREE mode, input=$IN output=$OUT"
	find_live "$IN"
	echo "==> remaster-uefi: live=$LIVEDIR kernel=$KREL initrd=$IREL boot=$BOOTMODE"
	build_efi_image
	rm -f "$OUT"
	# -iso-level 3 = multi-extent, native >4 GiB file support (our squashfs).
	# Appended 0xef partition is the ESP; El Torito EFI points at it.
	xorriso -as mkisofs \
		-iso-level 3 -full-iso9660-filenames -r -J -joliet-long \
		-volid CORVID \
		-append_partition 2 0xef "$WORK/efi.img" \
		-appended_part_as_gpt \
		-eltorito-alt-boot \
		-e --interval:appended_partition_2:all:: \
		-no-emul-boot \
		-partition_offset 16 \
		-o "$OUT" \
		"$IN"
else
	# ================= LEGACY ISO MODE: add a UEFI boot record to an ISO ========
	echo "==> remaster-uefi: ISO mode, input=$IN output=$OUT"
	[ -f "$IN" ] || { echo "remaster-uefi: input '$IN' is neither a dir nor a file" >&2; exit 1; }
	# mount-free inspection of the ISO for kernel/initrd
	_tmpx=$(mktemp -d);
	if command -v xorriso >/dev/null; then
		LIVEDIR=casper; BOOTMODE=casper
		xorriso -indev "$IN" -find /casper/filesystem.squashfs >/dev/null 2>&1 || { LIVEDIR=live; BOOTMODE=live; }
		KREL=$(xorriso -indev "$IN" -find "/$LIVEDIR" -name 'vmlinuz*' 2>/dev/null | head -1 | tr -d "'" | sed 's|^/||')
		IREL=$(xorriso -indev "$IN" -find "/$LIVEDIR" -name 'initrd*' 2>/dev/null | head -1 | tr -d "'" | sed 's|^/||')
	fi
	rm -rf "$_tmpx"
	[ -n "$KREL" ] && [ -n "$IREL" ] || { echo "remaster-uefi: kernel/initrd not found in ISO" >&2; exit 1; }
	build_efi_image
	rm -f "$OUT"
	xorriso -indev "$IN" -outdev "$OUT" \
		-volid CORVID \
		-map "$WORK/BOOTX64.EFI" /EFI/BOOT/BOOTX64.EFI \
		-append_partition 2 0xef "$WORK/efi.img" \
		-boot_image any efi_path=--interval:appended_partition_2:all:: \
		-boot_image any partition_table=on
fi

echo "==> remaster-uefi: wrote $OUT"
xorriso -indev "$OUT" -report_el_torito plain 2>&1 | grep -iE 'El Torito boot img' || \
	echo "remaster-uefi: WARNING - could not confirm El Torito EFI entry" >&2
