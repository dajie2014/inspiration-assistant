# -*- coding: utf-8 -*-
"""从谱子（MusicXML）里算出「每一段从第几秒开始」。

**为什么要它**：YuE2 出的是整首音频，歌词里就算写了 `[Verse 1]` / `[Chorus]`，
音频本身也**不带段落时间**。但同一首歌的 MusicXML 里，歌词是逐音节
对齐到小节和拍上的，而谱子和音频是同一首（实测：谱子总长和 flac 时长
差不到半秒）。所以段落边界可以从谱子反推。

**输入**：歌词文本（带 `[段落]` 标记）+ MusicXML + BPM。
**输出**：`[{"name": "Verse 1", "start": 15.1, "end": 45.2}, ...]`（秒）。

**找不到就不猜**：任何一段定位不到，就整首退回 `None` ——
宁可整首放进去，也不乱切。
"""
import re
import xml.etree.ElementTree as ET


def _norm(text):
    """只留字，去掉标点、空格、标记 —— 用来比对歌词。"""
    return re.sub(r"[^\w\u4e00-\u9fff]", "", text or "")


def parse_lyric_events(path):
    """返回 (events, bpm)。

    events: [{"beat": 全局拍数(quarter), "text": 音节}]，按谱面顺序。
    bpm:    谱子写的速度（没有就 None）。
    """
    root = ET.parse(path).getroot()

    # 旋律 part：优先有 <lyric> 的那个
    parts = root.findall(".//part")
    if not parts:
        raise ValueError("no <part> in score")
    part = None
    for candidate in parts:
        if candidate.findall(".//lyric"):
            part = candidate
            break
    if part is None:
        part = parts[0]

    bpm = None
    for sound in root.iter("sound"):
        if sound.get("tempo"):
            try:
                bpm = float(sound.get("tempo"))
            except ValueError:
                pass
            break
    if bpm is None:
        for direction in root.iter("direction"):
            for sound in direction.iter("sound"):
                if sound.get("tempo"):
                    try:
                        bpm = float(sound.get("tempo"))
                    except ValueError:
                        pass

    events = []
    beat = 0.0
    divisions = 1.0

    for measure in part.findall("measure"):
        attrs = measure.find("attributes")
        if attrs is not None:
            div = attrs.findtext("divisions")
            if div:
                try:
                    divisions = float(div)
                except ValueError:
                    pass

        for note in measure.findall("note"):
            duration = note.findtext("duration")
            dur = float(duration) if duration else 0.0
            is_chord = note.find("chord") is not None
            is_grace = note.find("grace") is not None

            lyric_text = None
            lyric = note.find("lyric")
            if lyric is not None:
                lyric_text = lyric.findtext("text")

            if lyric_text and not is_chord:
                events.append({"beat": beat, "text": lyric_text})

            if not is_chord and not is_grace:
                beat += dur / divisions

    return events, bpm


def parse_sections(lyrics):
    """把歌词按 `[段落]` 行切开：[(名字, [歌词行...]), ...]。没有标记就空。"""
    sections = []
    current = None
    for raw in (lyrics or "").splitlines():
        line = raw.strip()
        m = re.match(r"^\[(.+?)\]$", line)
        if m:
            if current is not None:
                sections.append(current)
            current = (m.group(1).strip(), [])
        elif current is not None and line:
            current[1].append(line)
    if current is not None:
        sections.append(current)
    return sections


def beat_to_seconds(beat, bpm):
    return beat / float(bpm) * 60.0


def find_line_beat(events, line):
    """在谱面歌词里找到某句的第一个字，返回那一拍的拍数。找不到返回 None。"""
    target = _norm(line)
    if not target:
        return None

    # 把音节拼起来，记下每个音节开始的位置
    pieces = []
    starts = []
    acc = ""
    for ev in events:
        starts.append((len(acc), ev["beat"]))
        acc += _norm(ev["text"])
        pieces.append(ev["text"])

    offset = acc.find(target[:8])          # 前八个字足够定位
    if offset < 0:
        offset = acc.find(target[:4])
    if offset < 0:
        return None

    beat = starts[0][1]
    for start, b in starts:
        if start <= offset:
            beat = b
        else:
            break
    return beat


def sections_from_score(lyrics, xml_path, bpm=None, tolerance=None):
    """主入口：`[段落]` 歌词 + MusicXML -> [{name,start,end}]（秒）。"""
    sections = parse_sections(lyrics)
    if not sections:
        return None

    events, score_bpm = parse_lyric_events(xml_path)
    if not events:
        return None
    bpm = bpm or score_bpm
    if not bpm:
        return None

    points = []
    last_beat = 0.0
    for name, lines in sections:
        if not lines:
            # 没有词的段落（如纯器乐 Intro）先占位，后面用它前后推
            points.append([name, None])
            continue
        beat = None
        for line in lines:
            beat = find_line_beat(events, line)
            if beat is not None:
                break
        if beat is None:
            return None
        points.append([name, beat])

    # 第一个有词的段落之前的段落（Intro 之类）从 0 开始
    known = [p for p in points if p[1] is not None]
    if not known:
        return None
    if points[0][1] is None:
        points[0][1] = 0.0
    # 其余无词段落填成"下一段的开始"（也就是上一段的结束）
    for i, p in enumerate(points):
        if p[1] is None:
            nxt = next((q[1] for q in points[i + 1:] if q[1] is not None), None)
            p[1] = nxt if nxt is not None else 0.0

    # 第一段始终从 0 开始：谱子前面就算有器乐前奏，也归第一段
    if points[0][1] > 0:
        points[0][1] = 0.0

    result = []
    for i, (name, sec_start) in enumerate(points):
        sec_end = points[i + 1][1] if i + 1 < len(points) else None
        result.append({
            "name": name,
            "start": round(beat_to_seconds(sec_start, bpm), 3),
            "end": round(beat_to_seconds(sec_end, bpm), 3) if sec_end else None,
        })
    return result
