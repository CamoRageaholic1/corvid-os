#!/bin/sh
# =============================================================================
# Corvid OS — asset generation + staging  (build-prep step)
# =============================================================================
# RUN THIS BEFORE `lb build`. It:
#   1. Rasterizes the hand-authored SVGs to PNG (rsvg-convert / ImageMagick),
#      falling back to the pure-Python generator when no SVG toolchain exists,
#      so a real raster asset ALWAYS exists.
#   2. Propagates the product NAME from branding/os-release (single source of
#      truth) into every derived file — os-release, Calamares branding.desc,
#      the KDE wallpaper metadata, and the boot splashes.
#   3. Stages everything into config/includes.chroot/... and config/
#      includes.binary/... where live-build and the 0600 branding hook expect
#      it.
#
# Safe to run repeatedly (idempotent). Author-config only — never runs lb build.
#
# Runs automatically from auto/build ahead of `lb config && lb build`. It is
# the one prep step that turns the vector sources into the raster + staged
# assets the ISO consumes.
# -----------------------------------------------------------------------------
set -e

HERE=$(cd "$(dirname "$0")" && pwd)     # branding/
ROOT=$(cd "$HERE/.." && pwd)            # repo root
INC="$ROOT/config/includes.chroot"
BIN="$ROOT/config/includes.binary"
ASSETS="$HERE/assets"

# ---- 1. canonical name (single source of truth) -----------------------------
# shellcheck disable=SC1090
. "$HERE/os-release"
NAME_VAL="${CORVID_NAME:-${NAME:-Corvid OS}}"
SHORT_VAL="${CORVID_SHORTNAME:-Corvid}"
ID_VAL="${CORVID_ID:-${ID:-corvid}}"
BUILD_STAMP="corvid-$(date +%Y%m%d)"
echo "==> Corvid asset build for: $NAME_VAL ($ID_VAL) / $BUILD_STAMP"

# ---- 2. rasterize SVG -> PNG (tiered), else python fallback -----------------
mkdir -p "$ASSETS"

# Always (re)build the pure-Python baseline first so a raster asset exists even
# with zero image tooling; the SVG rasterizers below overwrite with crisper art.
if command -v python3 >/dev/null 2>&1; then
    python3 "$HERE/generate-pngs.py"
fi

render() {  # render <svg> <out.png> <w> <h>
    _svg="$1"; _png="$2"; _w="$3"; _h="$4"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$_w" -h "$_h" "$_svg" -o "$_png"
    elif command -v magick >/dev/null 2>&1; then
        magick -background none "$_svg" -resize "${_w}x${_h}" "$_png"
    elif command -v convert >/dev/null 2>&1; then
        convert -background none -resize "${_w}x${_h}" "$_svg" "$_png"
    else
        echo "    (no SVG rasterizer; keeping python-generated $(basename "$_png"))"
    fi
}
render "$HERE/corvid-wallpaper.svg" "$ASSETS/wallpaper-1920x1080.png" 1920 1080
render "$HERE/corvid-wordmark.svg"  "$ASSETS/logo-512.png"            512  512
render "$HERE/corvid-wallpaper.svg" "$ASSETS/splash-640x480.png"      640  480

WALL="$ASSETS/wallpaper-1920x1080.png"
LOGO="$ASSETS/logo-512.png"
SPLASH="$ASSETS/splash-640x480.png"

# ---- 3. os-release -> staged /etc/os-release (clean + stamped) --------------
mkdir -p "$INC/etc"
{
    echo "# /etc/os-release for $NAME_VAL"
    echo "# GENERATED FROM branding/os-release BY generate-assets.sh — do not hand-edit."
    grep -vE '^[[:space:]]*#|^[[:space:]]*$|^CORVID_' "$HERE/os-release" \
        | sed "s|^BUILD_ID=.*|BUILD_ID=\"$BUILD_STAMP\"|"
} > "$INC/etc/os-release"

# ---- 4. Plymouth theme ------------------------------------------------------
PLY="$INC/usr/share/plymouth/themes/corvid"
mkdir -p "$PLY"
cp "$HERE/plymouth/corvid.plymouth" "$PLY/corvid.plymouth"
cp "$HERE/plymouth/corvid.script"   "$PLY/corvid.script"
cp "$WALL" "$PLY/background.png"
cp "$LOGO" "$PLY/logo.png"

# ---- 5. KDE wallpaper package (/usr/share/wallpapers/Corvid) ----------------
WP="$INC/usr/share/wallpapers/Corvid"
mkdir -p "$WP/contents/images"
cp "$WALL" "$WP/contents/images/1920x1080.png"
cp "$WALL" "$WP/contents/screenshot.png"
cat > "$WP/metadata.desktop" <<EOF
[Desktop Entry]
Name=$NAME_VAL
X-KDE-PluginInfo-Name=Corvid
X-KDE-PluginInfo-Author=Corvid OS
X-KDE-PluginInfo-License=CC-BY-SA-4.0
EOF

# ---- 6. distro icon (menu / launcher / Calamares) ---------------------------
ICO="$INC/usr/share/icons/hicolor/512x512/apps"
mkdir -p "$ICO"
cp "$LOGO" "$ICO/corvid.png"
mkdir -p "$INC/usr/share/pixmaps"
cp "$LOGO" "$INC/usr/share/pixmaps/corvid.png"

# ---- 7. Calamares config staged for the 0600 hook to install ----------------
CAL="$INC/usr/share/corvid/calamares"
rm -rf "$CAL"
mkdir -p "$CAL"
cp "$ROOT/calamares/settings.conf" "$CAL/settings.conf"
cp -r "$ROOT/calamares/modules"  "$CAL/modules"
cp -r "$ROOT/calamares/branding" "$CAL/branding"
cp "$LOGO" "$CAL/branding/corvid/logo.png"

# Propagate the product name from os-release into the Calamares branding.desc
# (keeps the name a single-source change).
BD="$CAL/branding/corvid/branding.desc"
sed -i.bak -E \
    -e "s|^([[:space:]]*productName:).*|\1         \"$NAME_VAL\"|" \
    -e "s|^([[:space:]]*shortProductName:).*|\1    \"$SHORT_VAL\"|" \
    -e "s|^([[:space:]]*bootloaderEntryName:).*|\1 \"$SHORT_VAL\"|" \
    "$BD"
rm -f "$BD.bak"

# ---- 8. boot-menu branding (config/includes.binary) -------------------------
mkdir -p "$BIN/isolinux" "$BIN/boot/grub"
cp "$SPLASH" "$BIN/isolinux/splash.png"        # BIOS/isolinux menu background
cp "$WALL"   "$BIN/boot/grub/splash.png"       # UEFI/GRUB menu background

# Propagate the product name into the boot-menu title / label (single source).
if [ -f "$BIN/isolinux/stdmenu.cfg" ]; then
    sed -i.bak -E "s|^MENU TITLE .*|MENU TITLE $NAME_VAL|" "$BIN/isolinux/stdmenu.cfg"
    rm -f "$BIN/isolinux/stdmenu.cfg.bak"
fi
if [ -f "$BIN/boot/grub/theme.txt" ]; then
    sed -i.bak -E "s|^([[:space:]]*text[[:space:]]*=).*|\1  \"$NAME_VAL\"|" "$BIN/boot/grub/theme.txt"
    rm -f "$BIN/boot/grub/theme.txt.bak"
fi

# ---- 9. real brand art overrides (photographic emblem + scene wallpaper) -----
# Steps 1-8 stage the SVG/placeholder art so the build never lacks an asset.
# This final step overlays the REAL brand images via the cross-platform Pillow
# renderer, so the photographic emblem (boot logo, icons) and the landscape
# scene (default wallpaper) win wherever they exist. It also builds the
# 'CorvidLogo' alternate wallpaper (emblem on black). Requires python3-pil.
if [ -f "$HERE/corvid-logo.png" ] && [ -f "$HERE/corvid-wallpaper-scene.png" ]; then
    if python3 -c "import PIL" >/dev/null 2>&1; then
        echo "==> Overlaying real brand art (render-branding.py)"
        python3 "$HERE/render-branding.py"
    else
        echo "W: python3-pil (Pillow) not found; keeping SVG placeholder art."
        echo "W: install it on the build VM with: sudo apt-get install -y python3-pil"
    fi
else
    echo "W: master brand images missing in branding/; keeping placeholder art."
fi

echo "==> Done. Staged into config/includes.chroot and config/includes.binary."
