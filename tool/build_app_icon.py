"""Turn the Smart Log brand artwork into launcher-icon sources.

The supplied artwork is a tall image: the log-in-a-viewfinder mark on top, the
"Smartlog" wordmark underneath. A launcher icon is rendered at 48px on a phone
home screen, where a wordmark is an illegible smudge -- so the wordmark is
dropped and only the mark is kept.

Usage:
    python tool/build_app_icon.py <source-image>

Writes:
    assets/logos/app_icon.png             1024x1024, mark on white
    assets/logos/app_icon_foreground.png  1024x1024, mark inset for Android
                                          adaptive icons (the outer ~25% is
                                          cropped away by the system mask)
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops

MASTER = 1024

# A gap of at least this fraction of the image height counts as the space
# between the mark and the wordmark, rather than an internal gap in the art.
MIN_WORDMARK_GAP = 0.04

# Android crops adaptive icons to a circle/squircle; the safe zone is the
# middle ~66%, which is what the mark has to land in for the viewfinder
# corners to survive.
#
# Not 0.66 though: flutter_launcher_icons wraps the foreground in a further
# 16% inset of its own. Composing at 0.66 would compound the two and leave
# the mark at ~55% of the icon, adrift in its own padding. 0.79 x 0.84 lands
# it on the real safe zone.
ADAPTIVE_SAFE_ZONE = 0.79

# The plain icon can sit closer to the edge, but not flush -- iOS rounds the
# corners and a mark touching the edge looks clipped.
STANDARD_SAFE_ZONE = 0.86


def content_mask(image, background):
    """A 1-bit view of "where is there actually artwork".

    Thresholded, because JPEG ringing means the background is never exactly
    one colour and an exact comparison would call the whole canvas content.
    """
    reference = Image.new(image.mode, image.size, background)
    diff = ImageChops.difference(image, reference).convert("L")

    return diff.point(lambda p: 255 if p > 20 else 0)


def trim_to_content(image, background):
    """Crop away uniform border, so padding is ours to control, not the file's."""
    bbox = content_mask(image, background).getbbox()

    return image.crop(bbox) if bbox else image


def isolate_mark(image, background):
    """Return just the logo mark, dropping a wordmark underneath it if present.

    The artwork comes in two shapes: the full lockup (mark above the word
    "Smartlog") and a pre-cropped mark on its own. Assuming the first and
    slicing off a fixed fraction silently beheads the second, so the split is
    detected instead: rows are grouped into bands of content separated by
    clear background, and only the topmost band is kept. A single-band image
    is returned whole.
    """
    mask = content_mask(image, background)
    rows = [
        mask.crop((0, y, mask.width, y + 1)).getextrema()[1] > 0
        for y in range(mask.height)
    ]

    bands = []
    start = None
    for y, filled in enumerate(rows + [False]):
        if filled and start is None:
            start = y
        elif not filled and start is not None:
            bands.append((start, y))
            start = None

    if not bands:
        return image

    # Merge bands separated by only a hairline gap -- those are gaps *inside*
    # the artwork (the space above the log, say), not the wordmark divider.
    min_gap = image.height * MIN_WORDMARK_GAP
    merged = [bands[0]]
    for top, bottom in bands[1:]:
        if top - merged[-1][1] < min_gap:
            merged[-1] = (merged[-1][0], bottom)
        else:
            merged.append((top, bottom))

    top, bottom = merged[0]
    print(f"content bands: {len(merged)} -> keeping rows {top}..{bottom}")

    return trim_to_content(image.crop((0, top, image.width, bottom)), background)


def compose(mark, safe_zone, background):
    """Scale the mark into a square canvas at the given safe-zone fraction.

    Uses resize() rather than thumbnail(): thumbnail only ever shrinks, so a
    source smaller than the target would be pasted at its original size and
    left swimming in a 1024px canvas.
    """
    target = MASTER * safe_zone
    scale = target / max(mark.size)

    scaled = mark.resize(
        (max(1, round(mark.width * scale)), max(1, round(mark.height * scale))),
        Image.LANCZOS,
    )

    canvas = Image.new("RGB", (MASTER, MASTER), background)
    canvas.paste(
        scaled,
        ((MASTER - scaled.width) // 2, (MASTER - scaled.height) // 2),
    )

    return canvas


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    source = Path(sys.argv[1])
    if not source.is_file():
        sys.exit(f"No such file: {source}")

    out_dir = Path(__file__).resolve().parent.parent / "assets" / "logos"
    out_dir.mkdir(parents=True, exist_ok=True)

    image = Image.open(source).convert("RGB")

    # Sample a corner rather than assuming pure white: the artwork sits on a
    # very light grey, and assuming #FFFFFF would leave a visible plate.
    background = image.getpixel((2, 2))

    mark = isolate_mark(image, background)

    print(f"source {image.size}  ->  mark {mark.size}  (bg {background})")

    if max(mark.size) < MASTER * 0.75:
        print(
            f"note: the mark is only {mark.width}x{mark.height}, so reaching "
            f"{MASTER}px means upscaling {MASTER / max(mark.size):.1f}x. "
            "A larger source would give a crisper icon."
        )

    for name, safe_zone in (
        ("app_icon.png", STANDARD_SAFE_ZONE),
        ("app_icon_foreground.png", ADAPTIVE_SAFE_ZONE),
    ):
        path = out_dir / name
        compose(mark, safe_zone, background).save(path, "PNG")
        print(f"wrote {path.relative_to(out_dir.parent.parent)}")


if __name__ == "__main__":
    main()
