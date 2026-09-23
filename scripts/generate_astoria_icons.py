"""Generate native app icons from assets/logos/astoria.png.

Requires Pillow: python -m pip install Pillow
Run from the repository root: python scripts/generate_astoria_icons.py
"""

import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/logos/astoria.png"
RESAMPLING = Image.Resampling.LANCZOS


def write_png(image: Image.Image, path: Path, size: int) -> None:
    image.resize((size, size), RESAMPLING).save(path, optimize=True)


def main() -> None:
    image = Image.open(SOURCE).convert("RGB")
    # The generated concept has pure white pixels outside its rounded frame.
    # Native launchers apply their own masks, so make those corners burgundy.
    image.putdata(
        [
            (83, 38, 53) if min(pixel) > 248 else pixel
            for pixel in image.get_flattened_data()
        ]
    )
    image.save(SOURCE, optimize=True)

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

        # Adaptive icons are masked by Android: keep the monogram within the
        # central safe area, with a matching burgundy background behind it.
        background = Image.new("RGB", (size, size), (83, 38, 53))
        inset = round(size * 0.16)
        inner = image.resize((size - inset * 2, size - inset * 2), RESAMPLING)
        background.paste(inner, (inset, inset))
        background.save(output / "ic_launcher_foreground.png", optimize=True)

    # Android 13 themed icons take their color from the OS. Use the bright
    # monogram as a silhouette and scale it into the adaptive icon's safe area.
    mask = image.convert("L").point(lambda light: 255 if light > 140 else 0)
    monochrome = Image.new("RGBA", image.size, (255, 255, 255, 0))
    mark = Image.new("RGBA", image.size, (255, 255, 255, 255))
    monochrome.paste(mark, (0, 0), mask)
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
