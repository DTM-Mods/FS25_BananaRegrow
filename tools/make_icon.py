"""Draw icon_bananaRegrow.png (256x256): a cut banana plant with a fresh shoot, on dark green.

Usage: python tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

MOD_DIR = Path(__file__).resolve().parent.parent
OUT = MOD_DIR / "icon_bananaRegrow.png"
SIZE = 256


def font(size):
    for name in ("arialbd.ttf", "Arial Bold.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # background: rounded dark green card with a lighter bottom band
    d.rounded_rectangle((4, 4, SIZE - 5, SIZE - 5), radius=28, fill=(26, 74, 36, 255), outline=(230, 200, 60, 255), width=4)
    d.rounded_rectangle((4, 176, SIZE - 5, SIZE - 5), radius=28, fill=(18, 52, 26, 255))
    d.rectangle((4, 176, SIZE - 5, 200), fill=(18, 52, 26, 255))

    # ground
    d.ellipse((40, 150, 216, 190), fill=(96, 64, 32, 255))

    # cut stump (left): brown trunk with a slanted cut face
    d.polygon([(70, 170), (118, 170), (114, 110), (74, 118)], fill=(120, 86, 40, 255))
    d.polygon([(74, 118), (114, 110), (110, 104), (78, 112)], fill=(220, 190, 120, 255))

    # fresh shoot (right): three bright leaves
    d.polygon([(160, 168), (150, 100), (176, 70), (184, 108), (176, 168)], fill=(80, 170, 60, 255))
    d.polygon([(168, 168), (118, 118), (104, 86), (150, 104), (170, 150)], fill=(60, 150, 50, 255))
    d.polygon([(168, 168), (212, 112), (232, 86), (190, 100), (174, 150)], fill=(100, 190, 70, 255))
    d.line((168, 168, 170, 108), fill=(140, 220, 110, 255), width=3)

    # a yellow banana bunch hint on the shoot
    d.pieslice((150, 60, 206, 116), start=200, end=330, fill=(240, 200, 50, 255))
    d.pieslice((154, 64, 202, 112), start=200, end=330, fill=(26, 74, 36, 255))

    # title
    f = font(40)
    title = "REGROW"
    w = d.textlength(title, font=f)
    d.text(((SIZE - w) / 2 + 2, 204 + 2), title, font=f, fill=(0, 0, 0, 160))
    d.text(((SIZE - w) / 2, 204), title, font=f, fill=(250, 220, 90, 255))

    img.save(OUT)
    print("wrote", OUT, img.size)


if __name__ == "__main__":
    main()
