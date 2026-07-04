#!/bin/sh
# Corvid OS -- provisioning/remaster-uefi.sh
# ===========================================================================
# Turns live-build 3.0's output ISO into a UEFI-bootable Corvid ISO. Called
# automatically by auto/build; can also be run by hand against a data ISO.
#
#   Usage: provisioning/remaster-uefi.sh [input.iso] [output.iso]
#     input.iso   the live-build data ISO; auto-detected if omitted
#     output.iso  the bootable result; default corvid-amd64.iso
#
# Why this is needed: Ubuntu's live-build 3.0 grub-efi stage produces an ISO
# with (a) no El Torito boot record and (b) no /boot/grub/grub.cfg at all -- it
# writes only the theme (splash.png/theme.txt). So we build a standalone GRUB
# x86_64-efi image whose BAKED-IN config finds the ISO (by /LIVEDIR/filesystem.
# squashfs), then boots the detected kernel + initrd with the correct live
# params. That EFI image is wrapped in a FAT ESP and registered as an El Torito
# EFI boot entry. Result is UEFI-only, which Ventoy + modern hardware boot fine.
#
# Requires: grub-common (grub-mkstandalone), grub-efi-amd64-bin, dosfstools
# (mkfs.vfat), mtools (mmd/mcopy), xorriso.
# ===========================================================================
set -e

IN="${1:-}"
OUT="${2:-corvid-amd64.iso}"

if [ -z "$IN" ]; then
	for _c in live-image-amd64.hybrid.iso corvid-amd64.hybrid.iso binary.hybrid.iso chroot/binary.hybrid.iso; do
		if [ -f "$_c" ]; then IN="$_c"; break; fi
	done
fi
if [ -z "$IN" ] || [ ! -f "$IN" ]; then
	echo "remaster-uefi: no input ISO found (pass one explicitly)" >&2
	exit 1
fi
for _t in grub-mkstandalone mkfs.vfat mmd mcopy xorriso; do
	command -v "$_t" >/dev/null 2>&1 || { echo "remaster-uefi: missing tool '$_t'" >&2; exit 1; }
done

echo "==> remaster-uefi: input=$IN  output=$OUT"

# --- detect the live directory (casper=Ubuntu, live=Debian) + kernel/initrd --
LIVEDIR=casper
BOOTMODE=casper
if ! xorriso -indev "$IN" -find /casper/filesystem.squashfs >/dev/null 2>&1; then
	LIVEDIR=live
	BOOTMODE=live
fi
KPATH=$(xorriso -indev "$IN" -find "/$LIVEDIR" -name 'vmlinuz*' 2>/dev/null | head -1 | tr -d "'")
IPATH=$(xorriso -indev "$IN" -find "/$LIVEDIR" -name 'initrd*' 2>/dev/null | head -1 | tr -d "'")
if [ -z "$KPATH" ] || [ -z "$IPATH" ]; then
	echo "remaster-uefi: could not find kernel/initrd under /$LIVEDIR in $IN" >&2
	exit 1
fi
echo "==> remaster-uefi: live=$LIVEDIR kernel=$KPATH initrd=$IPATH boot=$BOOTMODE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Baked-in GRUB config: find the ISO by a file we KNOW exists, then boot casper.
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
insmod echo
insmod test

search --no-floppy --set=root --file /$LIVEDIR/filesystem.squashfs
if [ -z "\$root" ]; then search --no-floppy --set=root --file /.disk/info; fi

set default=0
set timeout=5
menuentry "Corvid OS (live)" {
    linux (\$root)$KPATH boot=$BOOTMODE quiet splash ---
    initrd (\$root)$IPATH
}
menuentry "Corvid OS (safe graphics)" {
    linux (\$root)$KPATH boot=$BOOTMODE nomodeset ---
    initrd (\$root)$IPATH
}
EOF

grub-mkstandalone -O x86_64-efi -o "$WORK/BOOTX64.EFI" \
	"boot/grub/grub.cfg=$WORK/embed.cfg" \
	--modules="part_gpt part_msdos fat iso9660 search search_fs_file normal configfile linux gzio ls echo test all_video gfxterm"

dd if=/dev/zero of="$WORK/efi.img" bs=1M count=12 status=none
mkfs.vfat -n CORVIDEFI "$WORK/efi.img" >/dev/null
mmd -i "$WORK/efi.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK/efi.img" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

rm -f "$OUT"
xorriso -indev "$IN" -outdev "$OUT" \
	-volid CORVID \
	-map "$WORK/BOOTX64.EFI" /EFI/BOOT/BOOTX64.EFI \
	-append_partition 2 0xef "$WORK/efi.img" \
	-boot_image any efi_path=--interval:appended_partition_2:all:: \
	-boot_image any partition_table=on

echo "==> remaster-uefi: wrote $OUT"
xorriso -indev "$OUT" -report_el_torito plain 2>&1 | grep -iE 'El Torito boot img' || \
	echo "remaster-uefi: WARNING - could not confirm El Torito EFI entry" >&2
