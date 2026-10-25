#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""《灵感助手 使用手册》封面 —— 星空版（A4，1654×2339 @200dpi）。

用户 2026-10-25：「用灵感助手的欢迎画面给他的使用手册做一个封面。」

封面不是窗口截图，而是**照欢迎界面的画法重画一遍**：
星空（四团星云 + 250 颗星，种子与 `WelcomeView.swift` 的 Starfield 逐字相同）、
黑底白谱号的图标（同一支 Apple Symbols 的 U+1D11E）、发光标题、MI 徽章、标语。
横版欢迎画面铺不进 A4 竖页，所以按竖页重新排：上半是产品名，下半是书名。

    make_cover_starfield.py 输出.png --version 0.9.14 [--date "2026 年 10 月"]

★ 和 `make_cover.py` 的区别：那个是旧的"截图贴上半页"版（Letter 1701×2200），
  当前手册是 A4，封面也已经是这一版；旧脚本只作历史留着。
"""
import argparse
import math

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

# A4 @200dpi
W, H = 1654, 2339

CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
SF = "/System/Library/Fonts/SFNSRounded.ttf"
SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"


def cn(size, bold=True):
    return ImageFont.truetype(CN, size, index=2 if bold else 0)


def en(size):
    return ImageFont.truetype(SF, size)


def starfield(w, h, count=340):
    """照抄 WelcomeView.swift 里的 Starfield：同样的种子、同样的星云和星点。"""
    base = np.zeros((h, w, 3), dtype=np.float32)
    base[:] = (0.018, 0.018, 0.042)

    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    short = min(w, h)
    blobs = [
        (0.20, 0.26, 0.60, (0.30, 0.17, 0.62)),
        (0.84, 0.74, 0.56, (0.09, 0.27, 0.60)),
        (0.64, 0.14, 0.38, (0.48, 0.15, 0.36)),
        (0.10, 0.88, 0.44, (0.13, 0.33, 0.44)),
    ]
    for fx, fy, fr, col in blobs:
        cx, cy = fx * w, fy * h
        r = fr * short
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        a = np.clip(1.0 - d / r, 0.0, 1.0) * 0.32
        for c in range(3):
            base[..., c] += col[c] * a

    seed = 0x5DEECE66D
    mask = 0xFFFFFFFFFFFFFFFF

    def nxt():
        nonlocal seed
        seed = (seed * 6364136223846793005 + 1442695040888963407) & mask
        return ((seed >> 11) & 0x1FFFFFFFFFFFFF) / 0x20000000000000

    tints = [(1.0, 1.0, 1.0), (0.78, 0.86, 1.0), (1.0, 0.94, 0.82)]
    t = 0.0
    for _ in range(count):
        depth = nxt()
        x = nxt() * w
        y = nxt() * h
        radius = (0.5 + depth * 1.5) * 2.0          # pt → px（1pt=2px）
        brightness = 0.35 + depth * 0.6
        speed = 0.5 + nxt() * 1.7
        phase = nxt() * 2 * math.pi
        tint = tints[int(nxt() * 3) % 3]

        tw = 0.42 + 0.58 * (0.5 + 0.5 * math.sin(t * speed + phase))
        r = radius * (0.85 + 0.35 * tw)
        a = brightness * tw
        R = int(math.ceil(r * 3)) + 1
        x0, x1 = int(x) - R, int(x) + R + 1
        y0, y1 = int(y) - R, int(y) + R + 1
        xs0, xs1 = max(0, x0), min(w, x1)
        ys0, ys1 = max(0, y0), min(h, y1)
        if xs1 <= xs0 or ys1 <= ys0:
            continue
        gx = np.arange(xs0, xs1, dtype=np.float32) + 0.5
        gy = np.arange(ys0, ys1, dtype=np.float32) + 0.5
        gxx, gyy = np.meshgrid(gx, gy)
        dist = np.sqrt((gxx - x) ** 2 + (gyy - y) ** 2)
        spot = np.clip(1.0 - dist / max(r, 0.6), 0.0, 1.0) ** 1.4 * a
        for c in range(3):
            base[ys0:ys1, xs0:xs1, c] += spot * tint[c]

    return Image.fromarray(np.clip(base * 255.0, 0, 255).astype(np.uint8), "RGB")


def badge(canvas, cx, cy, side):
    """黑圆角方块 + 白色高音谱号 + 一圈蓝紫光晕（RGBA，四角透明）。"""
    SS = 4
    S = side * SS
    square = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(square)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.235), fill=(8, 8, 10, 255))
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.235),
                        outline=(46, 46, 50, 255), width=SS * 2)
    f = ImageFont.truetype(SYMBOLS, int(S * 0.80))
    bb = d.textbbox((0, 0), "\U0001D11E", font=f)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    d.text((S / 2 - tw / 2 - bb[0], S / 2 - th / 2 - bb[1] + S * 0.030),
           "\U0001D11E", font=f, fill=(255, 255, 255, 255))
    square = square.resize((side, side), Image.LANCZOS)

    # 光晕：以方块边缘为峰值向外衰减（整块实心圆会留下硬边，别用）
    pad = int(side * 0.95)
    size = pad * 2 + side
    gyy, gxx = np.mgrid[0:size, 0:size].astype(np.float32)
    r = np.sqrt((gxx - size / 2) ** 2 + (gyy - size / 2) ** 2)
    a = np.exp(-(((r - side * 0.50) / (side * 0.20)) ** 2)) * 0.62
    col = np.array((40, 54, 118), dtype=np.float32)
    glow = Image.fromarray((a[..., None] * col[None, None, :]).astype(np.uint8), "RGB")
    layer = Image.new("RGB", canvas.size, (0, 0, 0))
    layer.paste(glow, (cx - pad - side // 2, cy - pad - side // 2))
    canvas = ImageChops.screen(canvas, layer)

    canvas.paste(square, (cx - side // 2, cy - side // 2), square)
    return canvas


def spaced_width(draw, text, font, tracking):
    return sum(draw.textlength(ch, font=font) for ch in text) + tracking * (len(text) - 1)


def draw_spaced(draw_obj, xy, text, font, fill, tracking=0, anchor_center=True):
    x, y = xy
    if anchor_center:
        x -= spaced_width(draw_obj, text, font, tracking) / 2
    for ch in text:
        draw_obj.text((x, y), ch, font=font, fill=fill)
        x += draw_obj.textlength(ch, font=font) + tracking


def glow_text(base, text, font, xy, tracking, color, glow_colors):
    """先叠几层模糊的光，最后才写实心字 —— 顺序反了字会糊。"""
    for radius, strength, gcolor in glow_colors:
        layer = Image.new("RGB", base.size, (0, 0, 0))
        d = ImageDraw.Draw(layer)
        draw_spaced(d, xy, text, font, gcolor, tracking)
        blur = layer.filter(ImageFilter.GaussianBlur(radius))
        arr = np.asarray(blur).astype(np.float32) * strength
        blur = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
        base = ImageChops.screen(base, blur)
    d2 = ImageDraw.Draw(base)
    draw_spaced(d2, xy, text, font, color, tracking)
    return base


def build(version, date_text):
    img = starfield(W, H)
    cx = W // 2

    img = badge(img, cx, 560, 400)

    img = glow_text(img, "灵感助手", cn(156), (cx, 830), tracking=10,
                    color=(255, 255, 255),
                    glow_colors=[(30, 0.55, (255, 255, 255)),
                                 (80, 0.35, (90, 120, 255))])

    d = ImageDraw.Draw(img)
    badge_w, badge_h = 78, 48
    en_f = en(38)
    en_text = "Music Inspirationist"
    en_w = spaced_width(d, en_text, en_f, 6)
    bx = cx - (badge_w + 20 + en_w) // 2
    by = 1030
    d.rounded_rectangle([bx, by, bx + badge_w, by + badge_h], radius=11,
                        outline=(120, 128, 150), width=2)
    draw_spaced(d, (bx + badge_w / 2, by + 8), "MI", en(30), (176, 184, 206), 3)
    draw_spaced(d, (bx + badge_w + 20, by + 4), en_text, en_f,
                (150, 158, 182), 6, anchor_center=False)

    draw_spaced(d, (cx, 1130), "纯线下 AI 音乐创作", cn(40, bold=False),
                (122, 130, 152), 6)

    d.rectangle([cx - 150, 1700, cx + 150, 1704], fill=(214, 173, 55))

    img = glow_text(img, "使用手册", cn(200), (cx, 1790), tracking=16,
                    color=(255, 255, 255),
                    glow_colors=[(30, 0.45, (255, 255, 255))])

    foot = date_text
    if version:
        foot += f" · v{version}"
    d = ImageDraw.Draw(img)
    draw_spaced(d, (cx, 2170), foot, cn(38, bold=False), (109, 114, 128), 4)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--version", default="")
    ap.add_argument("--date", default="2026 年 10 月")
    a = ap.parse_args()
    img = build(a.version, a.date)
    img.save(a.out, optimize=True)
    print(f"✓ 封面 {img.width}×{img.height} → {a.out}")


if __name__ == "__main__":
    main()
