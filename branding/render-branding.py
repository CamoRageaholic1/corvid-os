#!/usr/bin/env python3
"""
Corvid OS - branding asset renderer.

Generates every derived branding asset from two master images:

    branding/corvid-logo.png            square CORVID OS emblem (boot logo, icons)
    branding/corvid-wallpaper-scene.png landscape default desktop wallpaper

Cross-platform (Pillow only), so it runs on macOS to commit baselines AND on the
Linux build VM (python3-pil) for a reproducible build. generate-assets.sh calls
this at the end so the real art always wins over the SVG placeholders.

Mapping:
    * Default desktop wallpaper  = the landscape scene   -> wallpapers/Corvid
    * Alternate wallpaper option = emblem on black        -> wallpapers/CorvidLogo
    * Boot splash (Plymouth)     = emblem centered on black
    * Bootloader menu splashes   = emblem centered on black
    * Calamares logo / app icon / pixmap = emblem
"""
import os
from PIL import Image

BR   = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(BR)
CH   = os.path.join(REPO, "config", "includes.chroot")
CB   = os.path.join(REPO, "config", "includes.binary")
CAL  = os.path.join(REPO, "calamares")
ASSETS = os.path.join(BR, "assets")

BLACK = (0, 0, 0, 255)


def _ensure(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)


def _load(name):
    return Image.open(os.path.join(BR, name)).convert("RGBA")


def save_rgb(img, path):
    _ensure(path)
    img.convert("RGB").save(path, "PNG")
    print("  wrote", os.path.relpath(path, REPO))


def save_rgba(img, path):
    _ensure(path)
    img.save(path, "PNG")
    print("  wrote", os.path.relpath(path, REPO))


def square(emblem, size):
    """Resize the (already square) emblem to size x size."""
    return emblem.resize((size, size), Image.LANCZOS)


def on_black(emblem, W, H, frac):
    """Emblem centered on a solid black WxH canvas; emblem longest side = frac*min(W,H)."""
    canvas = Image.new("RGBA", (W, H), BLACK)
    target = max(1, int(min(W, H) * frac))
    e = emblem.copy()
    e.thumbnail((target, target), Image.LANCZOS)
    canvas.alpha_composite(e, ((W - e.width) // 2, (H - e.height) // 2))
    return canvas


def cover(img, W, H):
    """Scale + center-crop img to exactly WxH (CSS 'cover')."""
    sw, sh = img.size
    s = max(W / sw, H / sh)
    nw, nh = int(sw * s + 0.5), int(sh * s + 0.5)
    r = img.resize((nw, nh), Image.LANCZOS)
    x, y = (nw - W) // 2, (nh - H) // 2
    return r.crop((x, y, x + W, y + H))


def main():
    emblem = _load("corvid-logo.png")
    scene = _load("corvid-wallpaper-scene.png")

    print("Corvid OS branding renderer")

    # --- DEFAULT wallpaper: the landscape scene (package 'Corvid') ---------------
    wp = cover(scene, 1920, 1080)
    save_rgb(wp, os.path.join(CH, "usr/share/wallpapers/Corvid/contents/images/1920x1080.png"))
    save_rgb(cover(scene, 2560, 1440), os.path.join(CH, "usr/share/wallpapers/Corvid/contents/images/2560x1440.png"))
    save_rgb(wp.resize((640, 360), Image.LANCZOS), os.path.join(CH, "usr/share/wallpapers/Corvid/contents/screenshot.png"))
    save_rgb(wp, os.path.join(ASSETS, "wallpaper-scene-1920x1080.png"))

    # --- ALTERNATE wallpaper option: emblem on black (package 'CorvidLogo') ------
    wl = on_black(emblem, 1920, 1080, 0.55)
    save_rgb(wl, os.path.join(CH, "usr/share/wallpapers/CorvidLogo/contents/images/1920x1080.png"))
    save_rgb(wl.resize((640, 360), Image.LANCZOS), os.path.join(CH, "usr/share/wallpapers/CorvidLogo/contents/screenshot.png"))
    save_rgb(wl, os.path.join(ASSETS, "wallpaper-logo-1920x1080.png"))

    # --- Boot splash (Plymouth): emblem centered on black ------------------------
    ply = os.path.join(CH, "usr/share/plymouth/themes/corvid")
    save_rgb(Image.new("RGBA", (1920, 1080), BLACK), os.path.join(ply, "background.png"))
    save_rgba(square(emblem, 512), os.path.join(ply, "logo.png"))

    # --- Bootloader menu splashes: emblem centered on black ----------------------
    save_rgb(on_black(emblem, 640, 480, 0.62), os.path.join(CB, "isolinux/splash.png"))
    save_rgb(on_black(emblem, 1920, 1080, 0.42), os.path.join(CB, "boot/grub/splash.png"))

    # --- Calamares logo / app icon / pixmap: emblem ------------------------------
    save_rgba(square(emblem, 200), os.path.join(CAL, "branding/corvid/logo.png"))
    save_rgba(square(emblem, 200), os.path.join(CH, "usr/share/corvid/calamares/branding/corvid/logo.png"))
    save_rgba(square(emblem, 512), os.path.join(CH, "usr/share/icons/hicolor/512x512/apps/corvid.png"))
    save_rgba(square(emblem, 256), os.path.join(CH, "usr/share/pixmaps/corvid.png"))

    print("Done.")


if __name__ == "__main__":
    main()
