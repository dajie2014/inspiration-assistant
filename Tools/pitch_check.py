#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从生成的音频里把**主旋律**抓出来，跟谱子对一遍。

为什么要有它（2026-10-13）
--------------------------------------------------------------------
「它到底有没有照谱唱」这件事，以前只能靠耳朵判。可它其实**能量**：
谱子给了一串「什么时间、什么音高」，音频里也能估出一串 ——
两串对得上才叫照谱，对不上就是模型自己编的。

这条判据的价值在于**它不依赖听感**：随时能复算、能拿两个版本对着比。
（"好不好听"仍然是人的事，这个工具不碰。）

用法
----
    pitch_check.py <音频> <谱子> [--bpm 每分钟拍数] [--limit 几处]

音频靠 ffmpeg 解码（本项目机器上有）；谱子读 MusicXML 或 ABC 的音符。
只用 numpy + 标准库。
"""

import argparse
import json
import math
import pathlib
import subprocess
import sys
import wave
from fractions import Fraction

import numpy as np

FFMPEG = "/opt/homebrew/bin/ffmpeg"
SR = 16000                      # 采样率：16k 够抓人声基频，算得也快
FRAME = 1024                    # 每帧 64ms
HOP = 256                       # 每 16ms 一帧
FMIN, FMAX = 70.0, 900.0        # 人声范围


def die(msg):
    sys.stderr.write(msg.rstrip() + "\n")
    raise SystemExit(2)


# ---------------------------------------------------------------- 音频 → 逐帧音高

def load_audio(path):
    """解码成 16k 单声道 float32（走 ffmpeg，失败就走 macOS 自带的 afconvert）。"""
    raw = pathlib.Path(path).with_suffix(".pcm16")
    cmd = [FFMPEG, "-v", "error", "-y", "-i", str(path),
           "-ac", "1", "-ar", str(SR), "-f", "s16le", str(raw)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not raw.exists():
        alt = pathlib.Path(path).with_suffix(".mono.wav")
        proc = subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}",
                               "-c", "1", str(path), str(alt)], capture_output=True, text=True)
        if proc.returncode != 0 or not alt.exists():
            die("音频解不开：" + (proc.stderr or "没给出原因")[:200])
        with wave.open(str(alt), "rb") as w:
            data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    else:
        data = np.frombuffer(raw.read_bytes(), dtype=np.int16)
    return data.astype(np.float32) / 32768.0


def f0_of(frame, sr=SR):
    """自相关估基频；不够自信就返回 None。

    为什么用自相关：人声是有明显周期的，而伴奏（钢琴）衰减快、
    落在同一帧里往往不盖过主旋律 —— 这套在"人声为主的歌"上够用。
    """
    frame = frame - frame.mean()
    energy = float(np.sqrt((frame ** 2).mean()))
    if energy < 0.01:                       # 太安静（间奏/留白）
        return None
    corr = np.correlate(frame, frame, mode="full")[len(frame) - 1:]
    corr /= (corr[0] + 1e-9)
    lo = int(sr / FMAX)
    hi = min(int(sr / FMIN), len(corr) - 1)
    if hi <= lo:
        return None
    peak = lo + int(np.argmax(corr[lo:hi]))
    if corr[peak] < 0.30:                   # 自相关不够强 ⇒ 不敢认
        return None
    return sr / peak


def melody_frames(samples):
    """整段音频 → [(秒, MIDI 或 None)]。"""
    out = []
    for start in range(0, len(samples) - FRAME, HOP):
        f = f0_of(samples[start:start + FRAME])
        midi = None if not f else 69 + 12 * math.log2(f / 440.0)
        out.append((start / SR, midi))
    return out


# ---------------------------------------------------------------- 谱子 → 时间轴上的目标

def score_notes(path):
    """谱子的音符 [(起点秒, MIDI, 时长秒)]，靠 MusicXML 或 ABC 读。"""
    p = pathlib.Path(path)
    text = p.read_text(encoding="utf-8", errors="replace")
    if p.suffix.lower() == ".abc":
        return _notes_from_abc(text)
    return _notes_from_musicxml(text)


_BASE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _notes_from_musicxml(text):
    import xml.etree.ElementTree as ET
    root = ET.fromstring(text)
    part = root.find("part")
    div, fifths, cursor, last = 1, 0, Fraction(0), Fraction(0)
    out = []
    for m in part.findall("measure"):
        a = m.find("attributes")
        if a is not None and a.findtext("divisions"):
            div = max(1, int(a.findtext("divisions")))
        for el in m:
            if el.tag == "note":
                dur = Fraction(int(el.findtext("duration", "0")), div)
                if el.find("chord") is not None:
                    onset = last
                else:
                    onset, last = cursor, cursor
                    cursor += dur
                if el.find("rest") is not None:
                    continue
                pit = el.find("pitch")
                if pit is None:
                    continue
                midi = ((int(pit.findtext("octave", "4")) + 1) * 12
                        + _BASE[pit.findtext("step")] + int(pit.findtext("alter", "0")))
                out.append((float(onset), midi, float(dur)))
            elif el.tag == "backup":
                cursor -= Fraction(int(el.findtext("duration", "0")), div)
            elif el.tag == "forward":
                cursor += Fraction(int(el.findtext("duration", "0")), div)
    return out


def _notes_from_abc(text):
    """够用的 ABC 读者：只认原生写法里的音符（`V: Vocal` 那一行）。"""
    unit = Fraction(1, 16)
    fifths, key_acc = 0, {}
    order = "FCGDAEB"
    out, time = [], Fraction(0)
    import re
    token = re.compile(r"(?P<acc>\^\^|__|\^|_|=)?(?P<note>[A-Ga-gz])"
                       r"(?P<oct>[,']*)(?P<dur>[0-9]*)(?P<tie>-?)")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("X:", "T:", "V:", "%")):
            continue
        if line.startswith("L:"):
            unit = Fraction(1, int(line[2:].split("/")[1]))
            continue
        if line.startswith("K:"):
            name = line[2:].strip()
            sharps = "FCGDAEB"[: max(0, {"C": 0, "G": 1, "D": 2, "A": 3, "E": 4,
                                         "B": 5, "F#": 6, "C#": 7}.get(name, 0))]
            flats = "BEADGCF"[: max(0, {"F": 1, "Bb": 2, "Eb": 3, "Ab": 4, "Db": 5}.get(name, 0))]
            key_acc = {}
            for s in sharps:
                key_acc[s] = 1
            for f in flats:
                key_acc[f] = -1
            continue
        if "|" not in line or ":" in line:
            continue
        for m in token.finditer(line):
            if m.group("note") == "z":
                time += Fraction(int(m.group("dur") or "1")) * unit * 4
                continue
            letter = m.group("note").upper()
            oct_mark = m.group("oct") or ""
            base_oct = 4 if m.group("note").isupper() else 5
            octave = base_oct + oct_mark.count("'") - oct_mark.count(",")
            acc = {"^": 1, "^^": 2, "_": -1, "__": -2, "=": 0}.get(m.group("acc") or "", None)
            semitone = _BASE[letter] + (acc if acc is not None else key_acc.get(letter, 0))
            dur = Fraction(int(m.group("dur") or "1")) * unit * 4
            out.append((float(time), (octave + 1) * 12 + semitone, float(dur)))
            time += dur
    return out


# ---------------------------------------------------------------- 比对

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("score")
    ap.add_argument("--bpm", type=float, default=None)
    ap.add_argument("--limit", type=int, default=6)
    args = ap.parse_args()

    notes = score_notes(args.score)
    if not notes:
        die("谱子里没读到音符")
    bpm = args.bpm
    if bpm is None:
        text = pathlib.Path(args.score).read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("Q:1/4="):
                bpm = float(line.split("=")[1])
                break
        if bpm is None:
            for line in text.splitlines():
                if "tempo" in line:
                    import re
                    m = re.search(r'tempo="([0-9.]+)"', line)
                    if m:
                        bpm = float(m.group(1))
                        break
    bpm = bpm or 120.0
    sec_per_quarter = 60.0 / bpm

    frames = melody_frames(load_audio(args.audio))
    got = [(t, m) for t, m in frames if m is not None]
    if not got:
        die("音频里一个音高都没抓出来（是不是纯伴奏？）")

    hit = miss = 0
    examples = []
    for t, m in got:
        quarter = t / sec_per_quarter
        target = None
        for onset, midi, dur in notes:
            if onset <= quarter < onset + max(dur, 0.05):
                target = midi
                break
        if target is None:
            continue
        # 容差：一个半音以内算对；**另外容一个八度** ——
        # 自相关估基频最容易错八度（尤其人声带泛音、底下还有钢琴时）。
        off = min(abs(m - target), abs(m - target - 12), abs(m - target + 12))
        if off <= 1.0:
            hit += 1
        else:
            miss += 1
            if len(examples) < args.limit:
                examples.append((round(t, 2), round(m, 1), target))

    total = hit + miss
    rate = (hit / total * 100) if total else 0.0
    print(json.dumps({
        "音频": pathlib.Path(args.audio).name,
        "谱子": pathlib.Path(args.score).name,
        "速度": bpm,
        "抓到音高的帧": len(got),
        "能对上谱子的帧": total,
        "吻合率": f"{rate:.1f}%",
        "对不上的": miss,
        "前几处对不上": [{"秒": t, "听到": m, "谱上是": s} for t, m, s in examples],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
