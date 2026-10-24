#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一份 MusicXML 按声部拆成「唱的那一条」和「其余的」。

**为什么要拆**（2026-10-13 实测出来的）：

Composer Step 出的谱子通常有两个声部 —— `Vocal Melody`（人声）和
`Ins Melody`（伴奏旋律）。把它们整份送进 ACE Studio 时，
`import file` 会给**每条源轨各建一条轨**，而落点那条是 Sing 轨，
于是**伴奏也变成唱轨**（ACE 只按落点类型决定，不按声部性质）。

后果是 ACE 里两条都能唱：人声那条有词、伴奏那条只能唱「啦」。
干活的人打开 ACE 就得自己先删一条，否则合成时两条一起唱。

⇒ 所以拆开送：**人声 → Sing 轨**（带歌词），**其余的 → 普通 MIDI 轨**（只有音符，
不参与合成，留着当参考/改谱）。信息一个都不丢，只是各归各位。

**挑哪条当"唱"的判据**（沿用 `native_abc.py` 已经在用的那套，别两处不一样）：
  ① 声部名里含 vocal / voice / 唱 / 人声  → 选它
  ② 都没有，再找含 lead / melody 的
  ③ 再挑不出 → 退到第一条声部（**同时把 `confident` 报成 false**，
     让调用方知道这一趟是"猜的"）

用法：
    split_score_parts.py <源.musicxml> <输出目录>

输出（stdout，一行 JSON）：
    {
      "vocal":       "<只含唱声部的 .musicxml 路径>",   # 挑不出唱声部时为空
      "others":      "<其余声部的 .musicxml 路径>",     # 没有其余声部时为空
      "vocalName":   "Vocal Melody",
      "otherNames":  ["Ins Melody"],
      "confident":   true
    }

⚠️ 只有一个声部时**什么都不拆**：`vocal` 直接指向**原文件**，
   `others` 为空 —— 少一次复制，也少一处可能出错的地方。
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# 判据①：明确的"唱"。中英文都收 —— 谱子可能是 Dorico（英文声部名）
# 也可能是中文标题（实测用户的谱子是 `Vocal Melody` / `Ins Melody`）。
VOCAL_HINTS = ("vocal", "voice", "唱", "人声")
# 判据②：没有明说的，退到"主旋律"。
MELODY_HINTS = ("lead", "melody", "主旋律", "旋律")


def part_names(root):
    """→ [(id, 显示名), ...]，按 part-list 的顺序。"""
    names = []
    part_list = root.find("part-list")
    if part_list is None:
        return names
    for score_part in part_list.findall("score-part"):
        pid = score_part.get("id")
        text = ""
        for tag in ("part-name", "part-abbreviation"):
            found = score_part.find(tag)
            if found is not None and (found.text or "").strip():
                text = found.text.strip()
                break
        names.append((pid, text))
    return names


def pick_vocal(names):
    """谁唱 → (part id, 有没有把握)。判据见文件头。"""
    if not names:
        return None, False

    def hit(hints):
        for pid, name in names:
            low = name.lower()
            if any(h in low for h in hints):
                return pid
        return None

    found = hit(VOCAL_HINTS)
    if found:
        return found, True
    found = hit(MELODY_HINTS)
    if found:
        return found, True
    # 都不像 —— 拿第一条顶上，但如实说这是猜的
    return names[0][0], False


def write_subset(root, keep, destination):
    """把 `keep` 之外的所有 `<part>` 与它们的 `<score-part>` 摘掉，另存一份。

    就地改 `root` 是安全的 —— 调用方为每种切法各解析一次源文件
    （MusicXML 动辄几百 KB，重解析比深拷贝更好懂）。
    """
    for part in list(root.findall("part")):
        if part.get("id") not in keep:
            root.remove(part)
    part_list = root.find("part-list")
    if part_list is not None:
        for score_part in list(part_list.findall("score-part")):
            if score_part.get("id") not in keep:
                part_list.remove(score_part)
    ET.ElementTree(root).write(destination, encoding="utf-8", xml_declaration=True)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("用法：split_score_parts.py <源.musicxml> <输出目录>", file=sys.stderr)
        return 2

    source, out_dir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(source):
        print(f"找不到谱子：{source}", file=sys.stderr)
        return 2

    names = part_names(ET.parse(source).getroot())
    if len(names) <= 1:
        # 只有一条声部 —— 不拆，直接把它当唯一的谱子
        print(json.dumps({
            "vocal": source,
            "others": "",
            "vocalName": names[0][1] if names else "",
            "otherNames": [],
            "confident": True,
        }, ensure_ascii=False))
        return 0

    vocal_id, confident = pick_vocal(names)
    others = [pid for pid, _ in names if pid != vocal_id]
    name_of = dict(names)

    os.makedirs(out_dir, exist_ok=True)
    stem = re.sub(r"[^0-9A-Za-z\u4e00-\u9fff]+", "-",
                  os.path.splitext(os.path.basename(source))[0])[:40] or "score"

    vocal_path = os.path.join(out_dir, f"{stem}.vocal.musicxml")
    write_subset(ET.parse(source).getroot(), {vocal_id}, vocal_path)

    others_path = ""
    if others:
        others_path = os.path.join(out_dir, f"{stem}.others.musicxml")
        write_subset(ET.parse(source).getroot(), set(others), others_path)

    print(json.dumps({
        "vocal": vocal_path,
        "others": others_path,
        "vocalName": name_of.get(vocal_id, ""),
        "otherNames": [name_of.get(pid, "") for pid in others],
        "confident": confident,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
