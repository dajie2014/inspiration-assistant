#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把**前奏那一段音频**锁住：第一次剪下来存着，以后每次生成都贴回去。

出处（用户 2026-10-26）：

    「最好的是能把前奏的内容给锁掉，然后用户改了之后，能按照用户改的来弄。」
    「伴奏是锁不死的。能锁死空间。」

为什么是剪音频，不是让模型照前奏的谱生成：照谱唱（`cot=melody`）**只读人声那一条**，
伴奏（含前奏）是模型自己配的，它不读你改的伴奏音。所以前奏只能从**成品音频**上锁。

怎么做：
  1. 从收拾好的 MusicXML 里算「第一个人声之前有几小节」→ 换成秒；
  2. 拿「这段谱 + 速度 + 风格 + 种子」做指纹；
  3. 指纹在缓存里 → 把缓存的那一截贴到新音频前面（人声之后的都保留新的）；
     不在 → 从新音频上切下这一截存起来（第一次就是它自己）。

⚠️ 指纹里包含速度、风格、种子：换了任何一样，前奏就当新的重新切。
⚠️ 这是**音频层**的操作 —— 只动开头那一截，人声和后面的伴奏一个字节不改。
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"


def tempo_from_abc(path):
    if not path:
        return None
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    match = re.search(r"^\s*Q:\s*1/4\s*=\s*(\d+)", text, re.M)
    return int(match.group(1)) if match else None


def intro_seconds(xml_path, tempo):
    """第一个人声之前有几小节 → 秒。

    只看**第一个 part**（人声）；`prepare_score` 已经把开头空拍处理过，
    所以这里看到的第一个有音的小节，就是人声进来的地方。
    """
    root = ET.parse(xml_path).getroot()
    parts = root.findall("part")
    if not parts:
        return None
    time_el = root.find(".//attributes/time")
    beats = int(time_el.findtext("beats")) if time_el is not None else 4
    beat_type = int(time_el.findtext("beat-type")) if time_el is not None else 4
    vocal = parts[0]
    measures = vocal.findall("measure")
    first = None
    for i, m in enumerate(measures):
        if any(n.find("pitch") is not None for n in m.iter("note")):
            first = i
            break
    if not first:
        return None
    bar_seconds = beats * (4.0 / beat_type) * 60.0 / tempo
    return first * bar_seconds


def fingerprint(xml_path, tempo, style, seed, bars):
    """这段前奏「长什么样」—— 谱 + 速度 + 风格 + 种子，少一样都不算同一段。"""
    root = ET.parse(xml_path).getroot()
    chunk = []
    for part in root.findall("part"):
        for m in part.findall("measure")[:bars]:
            chunk.append(ET.tostring(m, encoding="unicode"))
    raw = "\n".join(chunk) + f"\n|tempo={tempo}|style={style}|seed={seed}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def duration(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", path], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return None


def cut_intro(audio, seconds, dest):
    """把 [0, seconds) 切出来存成 wav（无损、统一格式，方便以后贴）。"""
    subprocess.run([FFMPEG, "-v", "error", "-y", "-i", audio, "-t", f"{seconds:.3f}",
                    "-c:a", "pcm_s16le", dest], check=True)


def paste_intro(audio, intro_wav, seconds, dest):
    """intro.wav + audio[seconds:] → dest（flac 无损）。"""
    subprocess.run([
        FFMPEG, "-v", "error", "-y", "-i", intro_wav, "-i", audio,
        "-filter_complex",
        f"[1:a]atrim=start={seconds:.3f},asetpts=PTS-STARTPTS[body];"
        f"[0:a][body]concat=n=2:v=0:a=1[out]",
        "-map", "[out]", "-c:a", "flac", dest,
    ], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xml", required=True, help="收拾好的 MusicXML（prepare_score 的产物）")
    parser.add_argument("--audio", required=True, help="这一轮生成的音频")
    parser.add_argument("--abc", default="", help="这一轮的谱（取速度用）")
    parser.add_argument("--cache-dir", default="", help="前奏缓存目录")
    parser.add_argument("--style", default="")
    parser.add_argument("--seed", default="")
    parser.add_argument("--apply", action="store_true", help="真的改音频（不加就只算、只看）")
    args = parser.parse_args()

    cache_dir = args.cache_dir or os.path.join(
        os.path.expanduser("~"), "Library", "Application Support", "Composer Bridge", "intros")

    tempo = tempo_from_abc(args.abc) or 120
    seconds = intro_seconds(args.xml, tempo)
    if not seconds or seconds < 0.5:
        print(json.dumps({"ok": True, "introSeconds": 0, "action": "none",
                          "message": "没有前奏（人声从头就开始）"}, ensure_ascii=False))
        return 0

    total = duration(args.audio)
    if total and seconds >= total - 1:
        print(json.dumps({"ok": False, "error": "算出来的前奏比整首歌还长，不做"},
                         ensure_ascii=False))
        return 1

    # 指纹要知道前奏有几小节
    root = ET.parse(args.xml).getroot()
    vocal = root.findall("part")[0]
    bars = next((i for i, m in enumerate(vocal.findall("measure"))
                 if any(n.find("pitch") is not None for n in m.iter("note"))), 0)
    key = fingerprint(args.xml, tempo, args.style, args.seed, bars)
    os.makedirs(cache_dir, exist_ok=True)
    cached = os.path.join(cache_dir, key + ".wav")

    if not args.apply:
        print(json.dumps({"ok": True, "introSeconds": round(seconds, 3), "bars": bars,
                          "key": key[:12], "cached": os.path.exists(cached),
                          "action": "dry"}, ensure_ascii=False))
        return 0

    if os.path.exists(cached):
        tmp = args.audio + ".intro-tmp.flac"
        paste_intro(args.audio, cached, seconds, tmp)
        os.replace(tmp, args.audio)
        print(json.dumps({"ok": True, "introSeconds": round(seconds, 3), "bars": bars,
                          "key": key[:12], "action": "pasted"}, ensure_ascii=False))
        return 0

    # 第一次：把这一截存起来，下一次开始就能贴
    cut_intro(args.audio, seconds, cached)
    print(json.dumps({"ok": True, "introSeconds": round(seconds, 3), "bars": bars,
                      "key": key[:12], "action": "stored"}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
