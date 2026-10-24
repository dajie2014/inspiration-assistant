#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 Composer Step 的程序图标：黑底 + 白色高音谱号。

怎么改图标：
  1. 改下面的 SIZE / RADIUS / FILL_BG / FILL_CLEF / FONT_SIZE
  2. 重跑本脚本（生成 icon/AppIcon.icns）
  3. 跑 gui/build.sh 重新打包（它会自动把 icns 放进 .app 里）

要点：
  * 高音谱号用的是系统自带 **Apple Symbols** 字体里的 U+1D11E。
    这台机器上实测只有它带这个字形（STIX、Arial Unicode 都没有）。
  * 圆角比例按苹果自家的 22.37%，这样在 Dock 里跟别的图标排一起不违和。
  * 先用大字号的矢量字形渲染成 1024，再逐级缩小 —— 小尺寸才不会糊成一团。

依赖：Pillow（DSH 自带的 Python 里有）
"""
from __future__ import annotations

import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

CLEF = "\U0001D11E"                                   # MUSICAL SYMBOL G CLEF
FONT_PATH = "/System/Library/Fonts/Apple Symbols.ttf"
SIZE = 1024
RADIUS = int(SIZE * 0.2237)
FILL_BG = (8, 8, 10, 255)                             # 近黑，比纯黑耐看一点
FILL_CLEF = (255, 255, 255, 255)
FONT_SIZE = 900                                       # 谱号高度约占画布 64%

HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(HERE, "AppIcon.iconset")
ICNS = os.path.join(HERE, "AppIcon.icns")


def main() -> int:
    if not os.path.exists(FONT_PATH):
        print(f"找不到字体：{FONT_PATH}", file=sys.stderr)
        return 1

    master = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(master)
    draw.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=RADIUS, fill=FILL_BG)

    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    bbox = draw.textbbox((0, 0), CLEF, font=font)
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(
        ((SIZE - width) / 2 - bbox[0], (SIZE - height) / 2 - bbox[1]),
        CLEF, font=font, fill=FILL_CLEF,
    )
    master.save(os.path.join(HERE, "icon-1024.png"))
    print(f"谱号墨迹 {width}x{height}（占画布 {height / SIZE:.0%} 高）")

    os.makedirs(ICONSET, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(ICONSET, name))

    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
    print(f"图标已生成：{ICNS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
