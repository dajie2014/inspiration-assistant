#!/usr/bin/env python3
"""把欢迎界面截图排成《使用手册》的封面。

用户 2026-10-18 要的：「封面就用我们的欢迎界面的图」。
一张 3:2 的窗口截图铺不满 A4/Letter 竖版，所以上半页放那张图、下半页放书名 ——
底色从截图自己的边角取，接缝看不出来。

用法（Tools/update_doc.sh 会自己调，平常不用手点）：

    make_cover.py docs/images/07-第一次打开.png docs/images/00-封面.png --version 0.9.3

出的图是 1701×2200（Letter 21.59×27.94cm @200dpi），
排版脚本按整页铺进去 —— 比例对不上就会多出一页白纸。
"""
import argparse

from PIL import Image, ImageDraw, ImageFont

CN_BOLD = "/System/Library/Fonts/Hiragino Sans GB.ttc"   # index 2 = W6
CN_REG = "/System/Library/Fonts/Hiragino Sans GB.ttc"    # index 0 = W3

GOLD = (201, 162, 39)
SOFT = (154, 160, 181)
DIM = (109, 114, 128)


def font(size, bold=False):
    return ImageFont.truetype(CN_BOLD, size,
                              index=2 if bold else 0)


def centered(draw, y, text, f, fill):
    w = draw.textlength(text, font=f)
    draw.text(((W - w) / 2, y), text, font=f, fill=fill)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("welcome")
    ap.add_argument("out")
    ap.add_argument("--version", default="")
    args = ap.parse_args()

    shot = Image.open(args.welcome).convert("RGB")
    # 截图是圆角窗口：四角那一点是窗口外的黑。裁掉一圈，
    # 图放上去就是直边，和下半页的底色接得上（不然左右各露出一小块黑角）。
    inset = max(6, round(shot.width * 0.008))
    shot = shot.crop((inset, inset, shot.width - inset, shot.height - inset))

    # 底色从截图的边角取 —— 图放上去以后，和下半页是一个颜色。
    bg = shot.getpixel((shot.width // 2, shot.height - 3))
    canvas = Image.new("RGB", (W, H), bg)

    # 上半页：欢迎图按页宽等比缩。
    img_h = round(shot.height * W / shot.width)
    canvas.paste(shot.resize((W, img_h), Image.LANCZOS), (0, 0))

    draw = ImageDraw.Draw(canvas)
    y = img_h

    centered(draw, y + 140, "灵感助手", font(170, True), (255, 255, 255))
    centered(draw, y + 375, "MI · Music Inspirationist", font(50), SOFT)

    draw.rectangle([(W / 2 - 150, y + 470), (W / 2 + 150, y + 473)], fill=GOLD)

    centered(draw, y + 545, "使用手册", font(120, True), (246, 246, 250))

    foot = "2026 年 10 月"
    if args.version:
        foot += f" · v{args.version}"
    centered(draw, H - 118, foot, font(36), DIM)

    canvas.save(args.out, optimize=True)
    print(f"✓ 封面 {W}×{H} → {args.out}")


# Letter 21.59 × 27.94cm @200dpi
W, H = 1701, 2200

if __name__ == "__main__":
    main()
