#!/usr/bin/env python3
"""把 docs/ 里的 markdown 文章转成 docx。

中文字体必须显式设 `w:eastAsia`——只设 run.font.name，
LibreOffice 转 PDF 时中文会掉回默认字体。（这个坑在说明书的生成脚本里踩过。）

★ 2026-10-11 从 composer-assistant 的 `Tools/make_article_docx.py` 整份拷来，
  按本项目的需要改了一处：**插图宽度不再写死 15cm**（见 `image()`）。
  那边是主本；将来若改排版，记得两边看一眼。
"""
import os
import re
import sys

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CN_FONT = "PingFang SC"
MONO = "Menlo"
ACCENT = RGBColor(0xB0, 0x7A, 0x2A)
DIM = RGBColor(0x6B, 0x6B, 0x6B)
QUOTE = RGBColor(0x3A, 0x3A, 0x3A)


def set_font(run, size=10.5, bold=False, color=None, italic=False, mono=False):
    name = MONO if mono else CN_FONT
    run.font.name = name
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color
    run._element.rPr.rFonts.set(qn("w:eastAsia"), CN_FONT)


def add_rich(p, text, size=10.5, color=None, bold=False, italic=False):
    """把 `**这样**` 变成真粗体，而不是把星号印在纸上。"""
    # 先剥掉行内代码的反引号，但保留内容
    text = re.sub(r"`([^`]+)`", r"\1", text)
    for i, seg in enumerate(text.split("**")):
        if not seg:
            continue
        set_font(p.add_run(seg), size, bold=(bold or i % 2 == 1),
                 color=color, italic=italic)


def para(doc, text="", size=10.5, bold=False, color=None, space_after=6,
         indent=0, italic=False, mono=False):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(space_after)
    p.paragraph_format.line_spacing = 1.45
    if indent:
        p.paragraph_format.left_indent = Cm(indent)
    if text:
        if "**" in text and not mono:
            add_rich(p, text, size, color, bold, italic)
        else:
            set_font(p.add_run(re.sub(r"`([^`]+)`", r"\1", text)),
                     size, bold, color, italic, mono)
    return p


def heading(doc, text, level):
    sizes = {1: 17, 2: 13.5, 3: 11.5}
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14 if level <= 2 else 10)
    p.paragraph_format.space_after = Pt(6)
    # ★ keep_with_next：标题不能孤零零留在页面最下面，正文（或图）翻到下一页去了。
    #   2026-10-11 加 —— 手册首版第一页就是「二、第一次打开」孤在页底。
    p.paragraph_format.keep_with_next = True
    add_rich(p, text, size=sizes.get(level, 11), bold=True,
             color=ACCENT if level <= 2 else None)
    return p


def bullet(doc, text, level=0):
    p = doc.add_paragraph(style="List Bullet")
    p.paragraph_format.space_after = Pt(3)
    p.paragraph_format.line_spacing = 1.4
    p.paragraph_format.left_indent = Cm(0.7 + 0.6 * level)
    add_rich(p, text, size=10)
    return p


def quote(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(8)
    p.paragraph_format.left_indent = Cm(0.8)
    p.paragraph_format.line_spacing = 1.4
    # 段内换行（引用里用 \n 表示）→ Word 的软换行，而不是新起一段
    for k, part in enumerate(text.split("\n")):
        if k:
            p.add_run().add_break()
        add_rich(p, part, size=10.5, color=QUOTE, italic=True)
    return p


def table(doc, rows, widths=None):
    cols = max(len(r) for r in rows)
    t = doc.add_table(rows=0, cols=cols)
    t.style = "Light Grid Accent 1"
    t.alignment = 1
    for ri, row in enumerate(rows):
        cells = t.add_row().cells
        for ci in range(cols):
            txt = row[ci] if ci < len(row) else ""
            cell = cells[ci]
            cell.text = ""
            p = cell.paragraphs[0]
            p.paragraph_format.space_after = Pt(1)
            add_rich(p, txt, size=9.5, bold=(ri == 0))
    if widths:
        for ri in range(len(t.rows)):
            for ci, w in enumerate(widths):
                if ci < len(t.columns):
                    t.rows[ri].cells[ci].width = Cm(w)
    return t


def image(doc, base_dir, rel, alt=""):
    """插一张图。

    ★ 相对路径**按正文所在目录**解析——markdown 里写的是 `images/xx.png`，
      而脚本可能从别处被调用。不这么做就会"找不到图"而静默跳过。

    宽度**按图自己的清晰度算**，上限 15cm（页面宽 21cm 去掉左右边距）。
    整屏截图（九百多像素）铺满 15cm 刚好清楚；可小窗口的截图只有四百多像素，
    硬撑到 15cm 等于 78dpi，字会糊成一团。按 150dpi 该多宽就多宽。
    （composer-assistant 那边写死 15cm，因为它的图都是整屏截图。）
    """
    path = rel if os.path.isabs(rel) else os.path.join(base_dir, rel)
    if not os.path.exists(path):
        # **如实写一行**，而不是静默跳过——图没了用户会以为是文档坏了
        para(doc, f"（图缺失：{rel}）", size=9.5, color=DIM)
        return
    width = 15.0
    try:
        from PIL import Image

        pixels = Image.open(path).size[0]
        width = min(15.0, pixels / 150 * 2.54)
    except Exception:                      # noqa: BLE001 —— 量不出来就用满宽
        pass
    doc.add_picture(path, width=Cm(width))
    doc.paragraphs[-1].alignment = WD_ALIGN_PARAGRAPH.CENTER
    if alt:
        cap = doc.add_paragraph()
        cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run = cap.add_run(alt)
        set_font(run, size=9, color=DIM)


def convert(md_path, out_path):
    lines = open(md_path, encoding="utf-8").read().split("\n")

    # 封面（2026-10-18 加）：正文第一行可以写
    #   <!-- cover: images/00-封面.png -->
    # 有这一行就出一张整页封面；没有就照旧从正文开始。
    cover = None
    m = re.match(r"<!--\s*cover:\s*(.*?)\s*-->$", lines[0].strip()) if lines else None
    if m:
        cover = m.group(1)
        lines = lines[1:]

    doc = Document()
    sec = doc.sections[0]
    if cover:
        path = cover if os.path.isabs(cover) else \
            os.path.join(os.path.dirname(os.path.abspath(md_path)), cover)
        if os.path.exists(path):
            sec.left_margin = sec.right_margin = Cm(0)
            sec.top_margin = sec.bottom_margin = Cm(0)
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(0)
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.0
            # 页宽 21.59cm；留 0.09 以免比纸张高出一点点、挤出空白页。
            p.add_run().add_picture(path, width=Cm(21.5))
            sec = doc.add_section(WD_SECTION.NEW_PAGE)
        else:
            para(doc, f"（封面缺失：{cover}）", size=9.5, color=DIM)
    sec.left_margin = sec.right_margin = Cm(2.2)
    sec.top_margin = sec.bottom_margin = Cm(2.0)

    i = 0
    while i < len(lines):
        line = lines[i]
        s = line.strip()

        # 代码块
        if s.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            for b in buf:
                p = para(doc, b if b.strip() else " ", size=9, mono=True,
                         space_after=0, indent=0.5)
                p.paragraph_format.line_spacing = 1.15
            para(doc, "", space_after=4)
            continue

        # 表格
        if s.startswith("|") and i + 1 < len(lines) and \
                set(lines[i + 1].strip()) <= set("|-: "):
            rows = []
            header = [c.strip() for c in s.strip("|").split("|")]
            rows.append(header)
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            table(doc, rows, widths=[4.5, 6.0, 6.0] if len(header) == 3 else None)
            para(doc, "", space_after=4)
            continue

        if s.startswith("# "):
            para(doc, s[2:], size=20, bold=True, color=ACCENT, space_after=10)
        elif s.startswith("## "):
            heading(doc, s[3:], 2)
        elif s.startswith("### "):
            heading(doc, s[4:], 3)
        elif s.startswith(">") and (s == ">" or s.startswith("> ")):
            # ★ **连续的 `>` 要合成一段。** 逐行成段的话，
            #   每行都带上下间距，读起来是散开的四条句子，不是一段引用。
            buf = []
            while i < len(lines) and (lines[i].strip() == ">"
                                      or lines[i].strip().startswith("> ")):
                t = lines[i].strip()
                buf.append(t[2:] if t.startswith("> ") else "")
                i += 1
            # 空行在引用内部保留成换行，段与段之间才断开
            merged, cur = [], []
            for b in buf:
                if b == "":
                    if cur:
                        merged.append("\n".join(cur)); cur = []
                    merged.append("")
                else:
                    cur.append(b)
            if cur:
                merged.append("\n".join(cur))
            for m in merged:
                if m == "":
                    continue
                quote(doc, m)
            continue
        elif (im := re.match(r"^!\[([^\]]*)\]\(([^)]+)\)", s)):
            # markdown 的插图。**必须放在这里**——它以前落到最后的 else，
            # 被当成普通文字排进去，于是导出的文档里一个字都不缺、就是没有图。
            image(doc, os.path.dirname(os.path.abspath(md_path)), im.group(2), im.group(1))
        elif re.match(r"^[-*] ", s):
            bullet(doc, s[2:])
        elif re.match(r"^\d+\. ", s):
            bullet(doc, re.sub(r"^\d+\. ", "", s))
        elif s == "---":
            para(doc, "", space_after=2)
        elif s == "":
            pass
        else:
            para(doc, s)
        i += 1

    doc.save(out_path)
    return out_path


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "docs", "如何给闭源产品做一个诚实的AI助手.md")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        ROOT, "docs", "如何给闭源产品做一个诚实的AI助手.docx")
    convert(src, dst)
    print(f"✓ 已生成 {os.path.relpath(dst, ROOT)}")
