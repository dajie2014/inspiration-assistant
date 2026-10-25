#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在最前面插入一页整页封面（不动正文、不动页码）。

用法：
    insert_cover.py 手册.docx 封面.png

● 封面单独成一节：页边距 0、没有页脚 → 图上没有页码。
● 图片是**浮动**的（锚在页面上，衬于文字下方），所以能精确铺满
  21 × 29.7cm，不会像行内图那样被段落行高挤出一圈白边。
● 正文那一节的页码仍从 1 开始（原 sectPr 原样保留）。
"""
import copy
import sys

from docx import Document
from docx.shared import Cm, Pt
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.text.paragraph import Paragraph

PAGE_W_CM = 21.0


def has_cover(body):
    first_p = body.find(qn("w:p"))
    return first_p is not None and first_p.find(".//" + qn("w:drawing")) is not None


def main(src, cover):
    doc = Document(src)
    body = doc.element.body
    if has_cover(body):
        print("第一段已经是一张图（封面），跳过")
        return 0

    sect = copy.deepcopy(doc.sections[0]._sectPr)
    for tag in ("w:headerReference", "w:footerReference"):
        for el in sect.findall(qn(tag)):
            sect.remove(el)
    pg_mar = sect.find(qn("w:pgMar"))
    for k in ("w:top", "w:right", "w:bottom", "w:left",
              "w:header", "w:footer", "w:gutter"):
        pg_mar.set(qn(k), "0")
    typ = sect.find(qn("w:type"))
    if typ is None:
        typ = OxmlElement("w:type")
        sect.insert(0, typ)
    typ.set(qn("w:val"), "nextPage")

    p = OxmlElement("w:p")
    body.insert(0, p)
    para = Paragraph(p, doc._body)
    para.paragraph_format.space_before = Pt(0)
    para.paragraph_format.space_after = Pt(0)

    run = para.add_run()
    run.add_picture(cover, width=Cm(PAGE_W_CM))
    drawing = run._r.find(qn("w:drawing"))
    inline = drawing.find(qn("wp:inline"))

    anchor = OxmlElement("wp:anchor")
    for k, v in dict(distT="0", distB="0", distL="0", distR="0", simplePos="0",
                     relativeHeight="1", behindDoc="1", locked="0",
                     layoutInCell="1", allowOverlap="1").items():
        anchor.set(k, v)
    sp = OxmlElement("wp:simplePos")
    sp.set("x", "0")
    sp.set("y", "0")
    anchor.append(sp)
    for tag in ("wp:positionH", "wp:positionV"):
        pos = OxmlElement(tag)
        pos.set("relativeFrom", "page")
        off = OxmlElement("wp:posOffset")
        off.text = "0"
        pos.append(off)
        anchor.append(pos)
    anchor.append(copy.deepcopy(inline.find(qn("wp:extent"))))
    ee = OxmlElement("wp:effectExtent")
    for k in ("l", "t", "r", "b"):
        ee.set(k, "0")
    anchor.append(ee)
    anchor.append(OxmlElement("wp:wrapNone"))
    anchor.append(copy.deepcopy(inline.find(qn("wp:docPr"))))
    anchor.append(copy.deepcopy(inline.find(qn("a:graphic"))))
    drawing.replace(inline, anchor)

    p.get_or_add_pPr().append(sect)      # 这一节到封面为止
    doc.save(src)
    print(f"封面已插入：{cover} → {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
