#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按人声音域给谱子挑谱号：女声用高音谱号，男声用低音谱号。

为什么：YuE2 出的谱子**几乎一律写高音谱号**，人声一低（C3 上下）整行全是加线，
进 Dorico 根本没法读。这个脚本看**人声部件的实际音高**再定谱号 ——
音域偏高的用 G2（高音），偏低的用 F4（低音）。

用法：
    python3 fix_score_clef.py 谱子.xml              # 就地改（原子写，不成功不留半截）
    python3 fix_score_clef.py 谱子.xml --dry-run    # 只看结论，不动文件
    python3 fix_score_clef.py 谱子.xml --force-f    # 强制低音谱号（调试用）

判据（2026-10-24 按用户定的规则量过本机 40 多份历史谱子）：
    1. **先看风格提示词**（`--prompt`）：写了女声就用高音谱号，写了男声就用低音谱号，不再猜。
    2. 提示词没写性别，才扫谱子：
       **默认就是高音谱号**（引擎出的谱本来就一律是高音谱号）；
       若**高音谱号下平均每个音要画 2 条以上加线**、而且换成低音谱号确实更少，
       就判定音域偏低，自动换低音谱号。
    3. 没有音符 / 找不到人声部件 → 不动，如实说。
平均加线的落点（历史谱子实测）：女声/中高音 0.0–1.5 条，偏低那批 2.1–6.8 条 ——
2 这条线正好落在空档里。
"""

import re
import sys

HIGH_LINE_LIMIT = 2.0    # 高音谱号下平均每音超过这么多条加线 → 换低音谱号
STEP = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
VOCAL_NAME = re.compile(r"vocal|voice|lead|sing|人声|主唱", re.I)


def parts(xml):
    """[(part_id, part_name)]，按 part-list 顺序。"""
    out = []
    for pid, block in re.findall(
            r'<score-part id="([^"]+)"[^>]*>(.*?)</score-part>', xml, re.S):
        m = re.search(r"<part-name>([^<]*)</part-name>", block)
        out.append((pid, (m.group(1) if m else "").strip()))
    return out


def midis_of(body):
    """该 part 里所有音符的 MIDI 音高（忽略休止符）。"""
    vals = []
    for pitch in re.findall(r"<pitch>(.*?)</pitch>", body, re.S):
        step = re.search(r"<step>([A-G])</step>", pitch)
        octave = re.search(r"<octave>(-?\d+)</octave>", pitch)
        if not step or not octave:
            continue
        alter = re.search(r"<alter>(-?\d+)</alter>", pitch)
        v = (int(octave.group(1)) + 1) * 12 + STEP[step.group(1)]
        if alter:
            v += int(alter.group(1))
        vals.append(v)
    return sorted(vals)


def midi_name(m):
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return f"{names[m % 12]}{m // 12 - 1}"


def lines_cost(vals, clef):
    """这个谱号下，所有音符超出五线一共要多画几条加线（越少越好读）。"""
    bottom, top = (64, 77) if clef == "G" else (43, 57)
    cost = 0
    for v in vals:
        if v > top:
            cost += (v - top + 1) // 2
        elif v < bottom:
            cost += (bottom - v + 1) // 2
    return cost


def detect_gender(prompt):
    """提示词里写了男女声就返回 'female'/'male'；没写返回 None。

    ★ 顺序要紧：`female` 里含 `male`，但 `\\bmale\\b` 有词边界，不会误中。
    """
    p = (prompt or "").lower()
    if re.search(r"\bfemale\b|\bwoman\b|\bgirl\b|女声|女生|女歌手|女嗓|女高音|女中音", p):
        return "female"
    if re.search(r"\bmale\b|\bman\b|\bboy\b|男声|男生|男歌手|男嗓|男高音|男低音", p):
        return "male"
    return None


def choose_clef(vals):
    """默认高音谱号；只有高音谱号下加线太多，才换低音谱号。

    返回 (sign, line, 说明)。
    """
    if not vals:
        return None
    g = lines_cost(vals, "G")
    avg_g = g / len(vals)
    if avg_g >= HIGH_LINE_LIMIT:
        f = lines_cost(vals, "F") / len(vals)
        # 只有换过去**真的更少加线**才换。极高音那首（A5–A6）高音谱号也要加线，
        # 但低音谱号会更糟 —— 那种保持高音。
        if f < avg_g:
            return ("F", "4",
                    f"高音谱号下平均每音 {avg_g:.1f} 条加线（太多；低音谱号只要 {f:.1f} 条）"
                    f" → 换低音谱号")
    return ("G", "2", f"高音谱号下平均每音 {avg_g:.1f} 条加线 → 保持高音谱号")


def set_clef(xml, part_id, sign, line):
    """只改这个 part 里的 clef；一个都不改就返回 (xml, 0)。"""
    m = re.search(r'(<part id="%s"[^>]*>)(.*?)(</part>)' % re.escape(part_id), xml, re.S)
    if not m:
        return xml, 0
    body = m.group(2)

    def repl(mm):
        return f"{mm.group(1)}{sign}{mm.group(2)}{line}{mm.group(3)}"

    new_body, n = re.subn(
        r"(<sign>)[A-Z](</sign>\s*<line>)\d+(</line>)", repl, body)
    if n == 0:
        return xml, 0
    return xml[:m.start(2)] + new_body + xml[m.end(2):], n


def main():
    argv = sys.argv[1:]
    flags = set()
    files = []
    prompt = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--prompt":
            prompt = argv[i + 1] if i + 1 < len(argv) else ""
            i += 2
            continue
        if a.startswith("--"):
            flags.add(a)
            i += 1
            continue
        files.append(a)
        i += 1
    if not files:
        print(__doc__)
        return 2
    path = files[0]
    try:
        xml = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"读不了 {path}：{e}")
        return 1

    candidates = [(pid, name) for pid, name in parts(xml) if VOCAL_NAME.search(name)]
    if not candidates:
        all_parts = parts(xml)
        if len(all_parts) == 1:
            candidates = all_parts
            print(f"没认出人声部件，整份谱只有一个声部「{candidates[0][1]}」，按它算")
        else:
            print("找不到人声部件（Vocal / Lead / 主唱…），不动这份谱")
            return 0

    pid, name = candidates[0]
    m = re.search(r'<part id="%s"[^>]*>(.*?)</part>' % re.escape(pid), xml, re.S)
    vals = midis_of(m.group(1) if m else "")
    if not vals:
        print(f"「{name}」里没有音符，不动这份谱")
        return 0

    gender = detect_gender(prompt)
    if "--force-f" in flags:
        sign, line, why = "F", "4", "强制低音谱号"
    elif gender == "female":
        sign, line, why = "G", "2", "提示词写了女声 → 高音谱号"
    elif gender == "male":
        sign, line, why = "F", "4", "提示词写了男声 → 低音谱号"
    else:
        choice = choose_clef(vals)
        if not choice:
            return 0
        sign, line, why = choice
        why = "提示词没写性别，" + why

    print(f"人声「{name}」音域 {midi_name(vals[0])}–{midi_name(vals[-1])}，"
          f"{len(vals)} 个音；{why}")

    if "--dry-run" in flags:
        return 0

    new_xml, changed = set_clef(xml, pid, sign, line)
    if changed == 0:
        print("谱子里没有可改的 <clef>（可能本来就对，或格式不标准），文件没动")
        return 0
    if new_xml == xml:
        print(f"本来就是 {sign}{line} 谱号，文件不用动")
        return 0
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_xml)
    import os
    os.replace(tmp, path)
    print(f"改好了：{changed} 处谱号 → {sign}{line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
