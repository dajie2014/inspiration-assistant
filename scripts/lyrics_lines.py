#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一份 MusicXML 的歌词，按「呼吸」分行；也能校验你手写的那份。

用法：
    自动分：  lyrics_lines.py <谱.musicxml> [--max 14]
    校验：    lyrics_lines.py <谱.musicxml> --check <你写的分行.txt>
    校验：    lyrics_lines.py <谱.musicxml> --check-params <界面的 params.json>

分行的两条规矩（2026-10-20 用户定的）：
  · **短休止（≈0.5 拍）＝换气**，不断行；
  · **长休止（≥1.5 拍）＝句界**（间奏/伴奏插入），断行。
另外加一条：一行太长听不出“呼吸”，所以到 `--max` 个字、
又刚好遇到一个休止（哪怕很短），也断一行。

⚠️ 只读，不改谱子。音节数按谱子数，不按你手写的数。
"""
import sys
import re
import json
import xml.etree.ElementTree as ET
from fractions import Fraction

SHORT = 0.5      # 换气
LONG = 1.5       # 句界


def read_events(path):
    """→ [(kind, payload)]，kind 是 'note'（payload=字，可能空）或 'rest'（payload=几拍）。"""
    root = ET.parse(path).getroot()
    parts = root.findall("part")
    # 挑人声那条（名字里有 vocal / voice / lead / 人声 / 唱）；挑不出就用第一条
    names = [n.text or "" for n in root.findall(".//part-name")]

    def is_vocal(name):
        low = name.lower()
        return any(k in low for k in ("vocal", "voice", "lead", "人声", "唱")) and "ins" not in low

    choose = 0
    for i, n in enumerate(names):
        if is_vocal(n):
            choose = i
            break
    part = parts[choose]

    divisions = 1
    events = []
    for m in part.findall("measure"):
        attrs = m.find("attributes")
        if attrs is not None:
            d = attrs.findtext("divisions")
            if d:
                divisions = max(1, int(d))
        for n in m.findall("note"):
            dur = Fraction(int(n.findtext("duration", "0")), divisions)
            if n.find("rest") is not None:
                # 相邻休止合并
                if events and events[-1][0] == "rest":
                    events[-1] = ("rest", events[-1][1] + float(dur))
                else:
                    events.append(("rest", float(dur)))
                continue
            tie = n.find("tie")
            if tie is not None and tie.get("type") == "stop":
                continue            # 连音接续：不重新占一个音节
            events.append(("note", n.findtext("lyric/text") or ""))
    return events, names[choose]


def auto_lines(events, max_chars=14, blank_on_long=False):
    """按呼吸分行。`blank_on_long=True` 时，长休止处额外插一个空行。

    2026-10-24 用户实测：模型对**分行**的敏感度大于谱子里的长休止 ——
    在长休止处给一个空行（段落级），比只换行更能让它"歇够了再重新起"。
    """
    lines, cur, pending_rest = [], "", 0.0
    for kind, val in events:
        if kind == "rest":
            pending_rest += val
            continue
        # 到了一个新音节：先看前面的休止要不要断
        if pending_rest >= LONG and cur:
            lines.append(cur)
            # 空行只给**长停顿**（≥3 拍，约一个小节），不是每句都给 ——
            # 每句都空行等于没有段落，模型反而更容易乱。
            if blank_on_long and pending_rest >= 3.0:
                lines.append("")
            cur = ""
        elif pending_rest >= SHORT and cur and len(cur) >= max_chars:
            lines.append(cur)
            cur = ""
        cur += val
        pending_rest = 0.0
    if cur:
        lines.append(cur)
    return lines if blank_on_long else [l for l in lines if l]


# 真正要跟谱子对的是「字」—— 空白和标点不占音位，别让它们把字数凑成对的。
PUNCT = "，。、；：！？…—·,.!?;:'\"“”‘’()（）[]【】《》<>~～/\\|"
_PUNCT_RE = re.compile("[" + re.escape(PUNCT) + r"\s]")


def clean_line(text):
    return _PUNCT_RE.sub("", text)


def lyrics_from_params(path):
    """界面 params.json 里的歌词 → [行]：丢掉空行和 [Verse] / [Chorus] 这类结构标签。"""
    doc = json.load(open(path, encoding="utf-8"))
    raw = doc.get("lyrics") or ""
    lines = []
    for line in raw.splitlines():
        t = line.strip()
        if not t or re.fullmatch(r"\[[^\]]*\]", t):
            continue
        lines.append(t)
    return lines


def check(events, lines):
    notes = [v for k, v in events if k == "note"]
    # 只数**有词**的音位 —— 谱子里的花腔/哼唱音位（无词）本来就不该有字。
    want = sum(1 for v in notes if v)
    got = sum(len(clean_line(l)) for l in lines)
    print(f"谱子人声音节：{want} 个；你写的分行：{got} 个字")
    if want == got:
        print("✓ 字数对得上")
        summary = f"词 {got} 字 = 谱 {want} 音 ✓"
    elif want > got:
        print(f"✗ 差 {want - got} 个字（谱子比你写的多：唱到后面会错位）")
        summary = f"词 {got} 字 / 谱 {want} 音，少 {want - got} 字（会错位）"
    else:
        print(f"✗ 多出 {got - want} 个字（谱子没这么多音位：唱不进去）")
        summary = f"词 {got} 字 / 谱 {want} 音，多 {got - want} 字（唱不进去）"
    # 逐行与谱子对齐，指出第一处对不上的行
    k = 0
    for i, line in enumerate(lines, 1):
        text = clean_line(line)
        chunk = notes[k:k + len(text)]
        k += len(text)
        if any(ch for ch in chunk if ch == "") or len(chunk) < len(text):
            print(f"  第 {i} 行落到了谱子的空位/末尾之外：{line[:20]}")
            break
    print(summary)          # 最后一行是**一句话摘要**，流程/进度用 tail -1 取它
    return want == got


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    events, part_name = read_events(path)
    notes = [v for k, v in events if k == "note"]
    words = "".join(notes)
    print(f"声部：{part_name} · 发音音 {len(notes)} 个 · 有词 {sum(1 for w in notes if w)} 个")

    if "--check" in args:
        i = args.index("--check")
        lines = [l.strip() for l in open(args[i + 1], encoding="utf-8") if l.strip()]
        check(events, lines)
        return 0

    # 直接从界面的 params.json 校验（流程里就是这么用的）：
    # 歌词框里的 [Verse] / [Chorus] 和空行都不是字，先剔掉再数。
    if "--check-params" in args:
        i = args.index("--check-params")
        lines = lyrics_from_params(args[i + 1])
        check(events, lines)
        return 0

    max_chars = 14
    if "--max" in args:
        max_chars = int(args[args.index("--max") + 1])
    blank = "--blank" in args
    lines = auto_lines(events, max_chars, blank_on_long=blank)
    real = [l for l in lines if l]
    print(f"自动切成 {len(real)} 行" + ("（长休止处留空行）" if blank else "") + "：")
    for l in lines:
        print("  " + l if l else "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
