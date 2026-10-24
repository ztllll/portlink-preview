"""Generate high-visibility, full-colour status artwork (Pillow only).

Run from any directory. Output is restricted to this project's assets/tray.
Only ready is green; idle, pending and failed are deliberately all red.
macOS loads the explicit 44px @2x files at 22 logical points, without template
rendering. Base 22px files also serve non-Retina/native Linux loading.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / "assets" / "tray"
POINT_SIZE = 22
SOURCE_SIZE = POINT_SIZE * 8
STATES = ("idle", "ready", "pending", "failed")
GREEN = (22, 163, 74, 255)
RED = (220, 38, 38, 255)
LIGHT_EDGE = (255, 255, 255, 245)
DARK_EDGE = (17, 24, 39, 245)
WHITE = (255, 255, 255, 255)


def draw_status(state: str) -> Image.Image:
    image = Image.new("RGBA", (SOURCE_SIZE, SOURCE_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    scale = SOURCE_SIZE / POINT_SIZE

    def box(values):
        return tuple(round(value * scale) for value in values)

    def round_line(points, width):
        points = [tuple(round(value * scale) for value in point) for point in points]
        pixels = round(width * scale)
        draw.line(points, fill=WHITE, width=pixels, joint="curve")
        radius = pixels / 2
        for x, y in points:
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=WHITE)

    # Large solid 19pt status disk, not thin chain strokes. The two contrasting
    # rims keep its silhouette distinct against either light or dark menu bars.
    draw.ellipse(box((0.5, 0.5, 21.5, 21.5)), fill=LIGHT_EDGE)
    draw.ellipse(box((1.1, 1.1, 20.9, 20.9)), fill=DARK_EDGE)
    draw.ellipse(box((1.7, 1.7, 20.3, 20.3)), fill=GREEN if state == "ready" else RED)

    # State is also distinguishable without relying solely on red/green vision.
    if state == "ready":
        round_line(((6.0, 11.2), (9.3, 14.5), (16.0, 7.8)), 2.4)
    elif state == "failed":
        round_line(((7.7, 7.7), (14.3, 14.3)), 2.4)
        round_line(((14.3, 7.7), (7.7, 14.3)), 2.4)
    elif state == "pending":
        round_line(((11.0, 6.8), (11.0, 11.8)), 2.4)
        draw.ellipse(box((9.7, 14.1, 12.3, 16.7)), fill=WHITE)
    else:
        round_line(((6.6, 11.0), (15.4, 11.0)), 2.4)
    return image


def check_artwork(image: Image.Image, state: str) -> None:
    opaque = [
        image.getpixel((x, y))
        for y in range(image.height)
        for x in range(image.width)
        if image.getpixel((x, y))[3] >= 220
    ]
    is_red = lambda pixel: pixel[0] > 160 and pixel[0] > pixel[1] * 1.5 and pixel[0] > pixel[2] * 1.5
    is_green = lambda pixel: pixel[1] > 100 and pixel[1] > pixel[0] * 1.5 and pixel[1] > pixel[2] * 1.5
    expected, opposite = (is_green, is_red) if state == "ready" else (is_red, is_green)
    assert sum(expected(pixel) for pixel in opaque) > image.width * image.height * 0.3
    assert sum(opposite(pixel) for pixel in opaque) == 0
    assert image.getpixel((0, 0))[3] == 0


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for state in STATES:
        source = draw_status(state)
        for scale, suffix in ((1, ""), (2, "@2x")):
            size = POINT_SIZE * scale
            image = source.resize((size, size), Image.Resampling.LANCZOS)
            check_artwork(image, state)
            image.save(ROOT / f"{state}{suffix}.png", optimize=True)
        source.save(
            ROOT / f"windows_{state}.ico",
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64)],
        )
    print("Generated 22px + 44px full-colour status PNGs and multi-size ICOs.")
    print("Ready: green. Every other state: red. Native iconSize: 22pt, isTemplate: false.")


if __name__ == "__main__":
    main()
