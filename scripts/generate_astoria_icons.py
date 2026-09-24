"""Generate the in-app mark and native icons from the original cat sticker.

Requires Pillow: python -m pip install Pillow
Run from the repository root: python scripts/generate_astoria_icons.py
"""

import json
from pathlib import Path

from PIL import Image, ImageChops


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/logos/astoria-sticker.png"
APP_LOGO = ROOT / "assets/logos/astoria.png"
CHARCOAL = (30, 30, 30)
RESAMPLING = Image.Resampling.LANCZOS


def write_png(image: Image.Image, path: Path, size: int) -> None:
    image.resize((size, size), RESAMPLING).save(path, optimize=True)


def main() -> None:
    sticker = Image.open(SOURCE).convert("RGBA")
    # Transparent artwork for the Flutter header/splash. Preserve the sticker's
    # shape, with enough room for its whiskers on a square canvas.
    square = Image.new("RGBA", (1024, 1024))
    scale = min(916 / sticker.width, 916 / sticker.height)
    thumb = sticker.resize(
        (round(sticker.width * scale), round(sticker.height * scale)), RESAMPLING
    )
    square.alpha_composite(
        thumb, ((1024 - thumb.width) // 2, (1024 - thumb.height) // 2)
    )
    square.save(APP_LOGO, optimize=True)

    # iOS icons cannot have transparency. Use the cat's own charcoal for the
    # backing so the transparent whisker gaps remain visible in every mask.
    image = Image.new("RGBA", square.size, (*CHARCOAL, 255))
    image.alpha_composite(square)
    image = image.convert("RGB")

    android = ROOT / "android/app/src/main/res"
    for folder, size in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        output = android / folder
        write_png(image, output / "ic_launcher.png", size)
        write_png(image, output / "ic_launcher_round.png", size)

        # The adaptive launcher masks the outer 1/6 on each side. Keep the
        # whiskers inside its safe area and let the XML supply the background.
        foreground = Image.new("RGBA", (size, size))
        inner = square.resize((round(size * 0.7), round(size * 0.7)), RESAMPLING)
        foreground.alpha_composite(
            inner, ((size - inner.width) // 2, (size - inner.height) // 2)
        )
        foreground.save(output / "ic_launcher_foreground.png", optimize=True)

    # A themed icon needs the facial features and white outline, not the solid
    # dark head (which would become a featureless silhouette).
    themed = square.resize((716, 716), RESAMPLING)
    mask = ImageChops.darker(
        themed.getchannel("R").point(lambda value: 255 if value > 120 else 0),
        themed.getchannel("A"),
    )
    monochrome = Image.new("RGBA", square.size)
    mark = Image.new("RGBA", themed.size, (255, 255, 255, 255))
    mark.putalpha(mask)
    monochrome.alpha_composite(
        mark, ((1024 - themed.width) // 2, (1024 - themed.height) // 2)
    )
    monochrome.save(android / "drawable-v24/ic_launcher_monochrome.png", optimize=True)

    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    manifest = json.loads((ios / "Contents.json").read_text(encoding="utf-8"))
    for entry in manifest["images"]:
        size = int(float(entry["size"].split("x")[0]) * int(entry["scale"][0]))
        write_png(image, ios / entry["filename"], size)

    macos = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write_png(image, macos / f"app_icon_{size}.png", size)

    image.save(
        ROOT / "windows/runner/resources/app_icon.ico",
        format="ICO",
        sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)],
    )


if __name__ == "__main__":
    main()
