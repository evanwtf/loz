#!/usr/bin/env python3
"""Derive the tvOS brand assets from the iOS app icon.

    python3 Tools/tvos-icon.py     # needs Pillow; rewrites Apps/ZeldatvOS/Assets.xcassets

tvOS cannot reuse the iOS icon as-is. Its home-screen icon is a *layered*
image (5:3, parallax) rather than a square, and the system also wants two
top-shelf banners at yet another aspect. So the one square PNG has to become
eleven images at four aspect ratios.

Doing that by resampling the 1024x1024 source would blur it: the artwork is
pixel art, and every tvOS size is a fractional multiple of 1024. Instead the
source is decomposed into the two things it is actually made of and each is
regenerated at the target size:

  - a 13x16 sprite at 48x magnification, origin (200, 108), four colours
  - a vertical gradient behind it, uniform across every row

The sprite is then re-magnified by an *integer* factor per size, so it stays
crisp everywhere, and the gradient is resampled, which is lossless for a
linear ramp. The split is unambiguous rather than tuned: the four sprite
colours have a maximum channel of 155 or more, and no background pixel exceeds
27, so any threshold in between recovers the same mask.

The layer split also earns its keep on tvOS, where the icon is parallaxed:
sprite in front, gradient behind, so it separates the way the platform expects.
"""

import json
import pathlib
import shutil

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Apps/ZeldaiOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
CATALOG = ROOT / "Apps/ZeldatvOS/Assets.xcassets"
BRAND = CATALOG / "AppIcon.brandassets"

# Where the sprite sits in the source, established by scanning for colour
# changes: they land on a 48-pixel grid whose origin is (200, 108).
BLOCK, ORIGIN, NATIVE = 48, (200, 108), (13, 16)
# Any cut between the background's brightest pixel (27) and the sprite's
# darkest (155) gives the same mask.
SPRITE_THRESHOLD = 60
# Fraction of the icon's height the sprite occupies, before rounding the
# magnification down to a whole number.
FILL = 0.70

INFO = {"author": "xcode", "version": 1}


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2) + "\n")


def load_parts():
    """Return the sprite as a 13x16 RGBA image and the gradient as a column."""
    source = Image.open(SOURCE).convert("RGB")
    pixels = source.load()

    sprite = Image.new("RGBA", NATIVE, (0, 0, 0, 0))
    for y in range(NATIVE[1]):
        for x in range(NATIVE[0]):
            # Sample each block's centre; the blocks are flat by construction.
            colour = pixels[ORIGIN[0] + x * BLOCK + BLOCK // 2,
                            ORIGIN[1] + y * BLOCK + BLOCK // 2]
            if max(colour) > SPRITE_THRESHOLD:
                sprite.putpixel((x, y), colour + (255,))

    # Column 0 is background for the full height, so it is the gradient itself.
    gradient = Image.new("RGB", (1, source.height))
    for y in range(source.height):
        gradient.putpixel((0, y), pixels[0, y])
    return sprite, gradient


def background(gradient, size):
    return gradient.resize(size, Image.LANCZOS).convert("RGBA")


def foreground(sprite, size, magnification):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    scaled = sprite.resize(
        (NATIVE[0] * magnification, NATIVE[1] * magnification), Image.NEAREST)
    layer.paste(scaled, ((size[0] - scaled.width) // 2,
                         (size[1] - scaled.height) // 2), scaled)
    return layer


def magnification_for(height):
    """Largest whole magnification that keeps the sprite within FILL."""
    return max(1, int(height * FILL) // NATIVE[1])


def imageset(path, renderer, base_size, scales):
    """An ordinary image set, one file per scale."""
    path.mkdir(parents=True, exist_ok=True)
    images = []
    for scale in scales:
        size = (base_size[0] * scale, base_size[1] * scale)
        name = f"{path.stem.lower().replace(' ', '-')}-{scale}x.png"
        renderer(size, scale).save(path / name, optimize=True)
        images.append({"filename": name, "idiom": "tv", "scale": f"{scale}x"})
    write_json(path / "Contents.json", {"images": images, "info": INFO})


def imagestack(path, sprite, gradient, base_size, scales):
    """A parallax stack: the sprite in front, the gradient behind."""
    path.mkdir(parents=True, exist_ok=True)
    # Front first — tvOS draws the list from the top layer down.
    write_json(path / "Contents.json", {
        "layers": [{"filename": "Front.imagestacklayer"},
                   {"filename": "Back.imagestacklayer"}],
        "info": INFO,
    })

    magnification = magnification_for(base_size[1])
    layers = {
        "Front": lambda size, scale: foreground(
            sprite, size, magnification * scale),
        "Back": lambda size, _: background(gradient, size),
    }
    for name, renderer in layers.items():
        layer = path / f"{name}.imagestacklayer"
        layer.mkdir(parents=True, exist_ok=True)
        write_json(layer / "Contents.json", {"info": INFO})
        imageset(layer / "Content.imageset", renderer, base_size, scales)


def main():
    sprite, gradient = load_parts()

    if CATALOG.exists():
        shutil.rmtree(CATALOG)
    BRAND.mkdir(parents=True)
    write_json(CATALOG / "Contents.json", {"info": INFO})

    def flat(size, scale):
        layer = background(gradient, size)
        layer.alpha_composite(
            foreground(sprite, size, magnification_for(size[1] // scale) * scale))
        return layer

    imagestack(BRAND / "App Icon.imagestack", sprite, gradient, (400, 240), [1, 2])
    # The App Store never sees this build, but Xcode expects the slot filled.
    imagestack(BRAND / "App Icon - App Store.imagestack", sprite, gradient,
               (1280, 768), [1])
    imageset(BRAND / "Top Shelf Image.imageset", flat, (1920, 720), [1, 2])
    imageset(BRAND / "Top Shelf Image Wide.imageset", flat, (2320, 720), [1, 2])

    write_json(BRAND / "Contents.json", {
        "assets": [
            {"filename": "App Icon.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "400x240"},
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv",
             "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
             "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": INFO,
    })


if __name__ == "__main__":
    main()
