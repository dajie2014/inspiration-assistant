#!/usr/bin/env python3
"""升版本时，把《使用手册》里该改的地方一次改完。

用户 2026-10-25 定的规矩：
  · **封面图上不写版本号**（写一次就要改一次，白费劲）——底下只留「2026 年 10 月」。
  · 版本号只出现在两处：**紧接封面的那一页**、**版本历史表第一行**。
  · 所以「每次版本更新都自动做这一步」= 跑这个脚本。

用法：
    python3 Tools/bump_manual.py 1.0.7 --note "能给一首歌换一副嗓子"

它会：
  1. 把封面图底部那行「… · vX.Y.Z」抹掉，只留年月（图里不再有版本号）
  2. 改内页的「版本：vX.Y.Z」
  3. 在「表 4 版本历史」最上面插一行，旧的「（当前版本）」去掉
  4. 导出一份新 PDF（用 DSH 自带的 LibreOffice Kit）
"""
import argparse
import re
import subprocess
import sys
import zipfile
from datetime import date
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
import numpy as np
from docx import Document

ROOT = Path(__file__).resolve().parent.parent
DOCX = ROOT / "灵感助手-使用手册.docx"
PDF = ROOT / "灵感助手-使用手册.pdf"
COVER_IN_DOCX = "word/media/image7.png"

LO_NODE = "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node"
LO_CLI = ("/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/"
          "@deepseek-ai/libreoffice-kit/lib/cli.js")

FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
DIM = (109, 114, 128)


def strip_cover_version(png_bytes: bytes) -> bytes:
    """把封面图底部那行末尾的「· vX.Y.Z」抹掉，只留年月。

    做法：整条横带用「上下一行背景」做纵向插值抹平，再写回年月 ——
    只填一小块会露出接缝（2026-10-25 试过，看得出来）。
    """
    import io

    img = Image.open(io.BytesIO(png_bytes)).convert("RGB")
    a = np.array(img).astype(np.float32)
    h, w, _ = a.shape

    y0, y1 = int(h * 0.892), int(h * 0.988)
    top = a[y0 - 6, :, :]
    bot = a[y1 + 6, :, :]
    for y in range(y0, y1):
        t = (y - y0) / (y1 - y0)
        a[y] = top * (1 - t) + bot * t

    img = Image.fromarray(a.astype(np.uint8))
    d = ImageDraw.Draw(img)
    text = f"{date.today().year} 年 {date.today().month} 月"
    d.text((w / 2, y0 + (y1 - y0) * 0.42), text,
           font=ImageFont.truetype(FONT, 44, index=0),
           fill=DIM, anchor="mm")

    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue()


def replace_zip_entry(docx: Path, name: str, data: bytes) -> None:
    """把 docx（zip）里的某个文件换掉，其余原样保留。"""
    tmp = docx.with_suffix(".tmp.docx")
    with zipfile.ZipFile(docx) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            payload = data if item.filename == name else src.read(item.filename)
            dst.writestr(item, payload)
    tmp.replace(docx)


def bump(version: str, note: str) -> None:
    doc = Document(str(DOCX))

    # 1. 内页版本号
    changed_page = False
    for p in doc.paragraphs:
        if p.text.strip().startswith("版本：v"):
            for run in p.runs:
                run.text = re.sub(r"v[\d.]+", f"v{version}", run.text)
            changed_page = "v" + version in p.text
    if not changed_page:
        sys.exit("没找到内页的「版本：v…」，手册结构可能变了")

    # 2. 版本历史表（表 4）：插一行，旧的去掉「（当前版本）」
    table = None
    for t in doc.tables:
        if len(t.columns) == 2 and t.rows and t.rows[0].cells[0].text.strip().startswith(("1.", "0.")):
            table = t
            break
    if table is None:
        sys.exit("没找到版本历史表")

    existing = {r.cells[0].text.strip().split("（")[0] for r in table.rows}
    if version not in existing:
        for r in table.rows:
            first = r.cells[0]
            if "（当前版本）" in first.text:
                for run in first.paragraphs[0].runs:
                    run.text = run.text.replace("（当前版本）", "")
                # 可能「（当前版本）」和数字在同一个 run 里，兜底再改一次
                if "（当前版本）" in first.text:
                    first.paragraphs[0].text = first.text.replace("（当前版本）", "")
        row = table.add_row()
        row.cells[0].text = f"{version}（当前版本）"
        row.cells[1].text = note
        # add_row 加在末尾；挪到最上面
        tbl = table._tbl
        tbl.remove(row._tr)
        tbl.insert(1, row._tr)   # 0 是表头（如果有），实际插到第一行之后
        # 表没有表头时，插到最前面
        if table.rows[0].cells[0].text.strip() != f"{version}（当前版本）":
            tbl.remove(row._tr)
            tbl.insert(0, row._tr)

    doc.save(str(DOCX))

    # 3. 封面图：抹掉版本号（图里不再写版本）
    with zipfile.ZipFile(DOCX) as z:
        if COVER_IN_DOCX in z.namelist():
            replace_zip_entry(DOCX, COVER_IN_DOCX, strip_cover_version(z.read(COVER_IN_DOCX)))
        else:
            print(f"⚠️ 封面图 {COVER_IN_DOCX} 不在文档里，跳过")

    print(f"✓ 手册已更新到 v{version}")


def export_pdf() -> None:
    if not Path(LO_NODE).exists() or not Path(LO_CLI).exists():
        print("⚠️ 找不到 LibreOffice Kit，PDF 没重出（下次手动导一次）")
        return
    out = PDF.with_name(PDF.stem + ".new.pdf")
    r = subprocess.run([LO_NODE, LO_CLI, "convert", "--input", str(DOCX), "--output", str(out)],
                       capture_output=True, text=True)
    if r.returncode == 0 and out.exists() and out.stat().st_size > 1000:
        out.replace(PDF)
        print(f"✓ PDF 已重出（{PDF.stat().st_size // 1024} KB）")
    else:
        print("⚠️ PDF 导出失败：", (r.stderr or r.stdout)[:300])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--note", default="")
    ap.add_argument("--no-pdf", action="store_true")
    args = ap.parse_args()
    bump(args.version, args.note or "本次更新")
    if not args.no_pdf:
        export_pdf()


if __name__ == "__main__":
    main()
