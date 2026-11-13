"""生成「剧播」启动图标：蓝色渐变圆角底 + 白色「剧」字。"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

RES = Path(r"E:/hongguomob/hgonly/app/android/app/src/main/res")
FONT = r"C:/Windows/Fonts/msyhbd.ttc"

TOP = (63, 123, 255)      # #3F7BFF
BOTTOM = (27, 63, 201)    # #1B3FC9
SS = 8                    # 超采样倍数

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}


def gradient(size: int) -> Image.Image:
    """155° 近似对角渐变。"""
    grad = Image.linear_gradient("L").rotate(-28, resample=Image.BICUBIC)
    grad = grad.resize((size, size), Image.BICUBIC)
    return Image.composite(
        Image.new("RGB", (size, size), BOTTOM),
        Image.new("RGB", (size, size), TOP),
        grad,
    )


def draw_glyph(canvas: Image.Image, ratio: float) -> None:
    """在画布正中画白色「剧」字，字高约为画布边长的 ratio。"""
    size = canvas.size[0]
    font_size = int(size * ratio)
    font = ImageFont.truetype(FONT, font_size)
    draw = ImageDraw.Draw(canvas)
    draw.text(
        (size / 2, size / 2),
        "剧",
        font=font,
        fill=(255, 255, 255, 255),
        anchor="mm",
        stroke_width=0,
    )


def launcher_png(px: int) -> Image.Image:
    """传统方形图标：圆角蓝色底 + 白字。"""
    big = px * SS
    bg = gradient(big).convert("RGBA")
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=255
    )
    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    tile.paste(bg, (0, 0), mask)
    draw_glyph(tile, 0.60)
    return tile.resize((px, px), Image.LANCZOS)


def foreground_png(px: int) -> Image.Image:
    """自适应图标前景：透明底 + 白字（内容落在中间 72/108 安全区内）。"""
    big = px * SS
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw_glyph(layer, 0.44)
    return layer.resize((px, px), Image.LANCZOS)


def main() -> None:
    for name, scale in DENSITIES.items():
        folder = RES / f"mipmap-{name}"
        folder.mkdir(parents=True, exist_ok=True)

        legacy = round(48 * scale)
        launcher_png(legacy).save(folder / "ic_launcher.png")

        fg = round(108 * scale)
        foreground_png(fg).save(folder / "ic_launcher_foreground.png")
        print(f"{name}: launcher {legacy}px, foreground {fg}px")

    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#2B5CF0</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    print("adaptive icon + colors written")


if __name__ == "__main__":
    main()
