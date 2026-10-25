#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 My Songwriter 的一首歌送进 Ableton Live。

**这条线只送音频，不碰乐谱。**
（用户 2026-10-18 定：Live 是循环汲取灵感的大工具，跟它打交道不需要
MusicXML；谱子只在往 ACE Studio 送的时候才用。）

用法：
    push_to_live.py "<产物目录>"
    push_to_live.py --audio 歌.flac --title 歌名 --track "AI 草稿"
    push_to_live.py --midi 拆轨.mid            # 拆轨 MIDI → 每条源轨一条 MIDI 轨

默认落点是**编曲视图**：接在这条轨已有内容末尾（空轨从第 1 小节），
不覆盖任何东西；`--clear` 先清空、`--at-bar N` 指定小节、
`--session` 放回 Session 的格子。

**速度不在这里算** —— 桥会让 Live 自己测速，再把工程节拍器写成它测出的值。

★ `--midi` 是 2026-10-25 加的（用户：「顺便加一个送MIDI到live的按钮」）。
  它在发送端把 MIDI 解析成音符（拍为单位），写成一份临时 JSON 让桥读 ——
  一份整曲 MIDI 塞不进一个 UDP 包。
"""
import argparse
import json
import os
import socket
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bpm import detect_bpm  # noqa: E402

PORT_FILE = os.path.join(tempfile.gettempdir(), "mysongwriter-live.port")
DEFAULT_PORT = 39032
AUDIO_EXTS = ("wav", "flac", "aiff", "aif", "mp3")


def read_port():
    try:
        with open(PORT_FILE) as f:
            return int(f.read().strip())
    except Exception:
        return DEFAULT_PORT


def send(payload, timeout=20.0):
    """发一条 UDP 给桥。

    超时放宽到 20 秒：桥可能要等 Live 分析完这首歌（测速）才回话。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        for _ in range(2):
            port = read_port()
            sock.sendto(json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                        ("127.0.0.1", port))
            try:
                data, _ = sock.recvfrom(65536)
                return json.loads(data.decode("utf-8"))
            except socket.timeout:
                continue
        raise RuntimeError(
            "Live 没回话。看看：① Live 开了吗？② 偏好设置里把 "
            "AbletonMySongwriter 选成控制面了吗？")
    finally:
        sock.close()


def pick_audio(folder):
    names = sorted(os.listdir(folder))
    for ext in AUDIO_EXTS:
        for name in names:
            if name.lower().endswith("." + ext):
                return os.path.join(folder, name)
    return None


def load_params(folder):
    path = os.path.join(folder, "params.json")
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _bar_text(bar):
    """小节号按人话打：整数就整数，落在半小节就留两位。"""
    if bar is None:
        return "?"
    value = float(bar)
    if abs(value - round(value)) < 0.001:
        return "%d" % int(round(value))
    return "%.2f" % value


def _num(value):
    """速度这类数：整数就整数，否则一位小数。"""
    if value is None:
        return "?"
    try:
        v = float(value)
    except Exception:
        return str(value)
    if abs(v - round(v)) < 0.01:
        return "%d" % int(round(v))
    return "%.1f" % v


# MARK: - 读 MIDI

def _vlq(data, index):
    """MIDI 的可变长数字（delta time 与 meta 长度都用它）。"""
    value = 0
    while True:
        byte = data[index]
        index += 1
        value = (value << 7) | (byte & 0x7F)
        if not (byte & 0x80):
            return value, index


def parse_midi(path):
    """→ [(轨道名, [[音高, 起点拍, 时长拍, 力度], ...]), ...]。

    为什么自己写：项目里没有 mido，而这里只需要音符与轨道名。
    规则跟 `MIDITrackNames.swift` 保持一致（同一件事别两处两套脾气）：
      · running status 要补回来；
      · note-on（力度 > 0）开始，note-off / 力度 0 结束；
      · 没有音符的轨（纯 tempo、拍号）跳过 —— 它们不该在 Live 里变成空轨。
    """
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 14 or data[:4] != b"MThd":
        raise ValueError("这不是一个 MIDI 文件")
    header_len = struct.unpack(">I", data[4:8])[0]
    count = struct.unpack(">H", data[10:12])[0]
    division = struct.unpack(">h", data[12:14])[0]
    if division <= 0:
        raise ValueError("这个 MIDI 用 SMPTE 记时，暂时不支持")

    position = 8 + header_len
    tracks = []
    for index in range(count):
        if data[position:position + 4] != b"MTrk":
            break
        length = struct.unpack(">I", data[position + 4:position + 8])[0]
        body = data[position + 8:position + 8 + length]
        position += 8 + length
        name, notes = _parse_track(body, division)
        if notes:
            tracks.append((name or ("MIDI %d" % (index + 1)), notes))
    return tracks


def _parse_track(body, division):
    index = 0
    tick = 0
    running = None
    name = ""
    notes = []
    open_notes = {}

    while index < len(body):
        delta, index = _vlq(body, index)
        tick += delta
        if index >= len(body):
            break
        status = body[index]
        if status < 0x80:
            if running is None:
                raise ValueError("轨道里有一条对不上的事件")
            status = running
        else:
            index += 1
            if status < 0xF0:
                running = status

        if status == 0xFF:
            kind = body[index]
            index += 1
            length, index = _vlq(body, index)
            payload = body[index:index + length]
            index += length
            if kind == 0x03 and not name:
                name = payload.decode("utf-8", "replace").strip()
            elif kind == 0x2F:
                break
            continue

        if status in (0xF0, 0xF7):
            length, index = _vlq(body, index)
            index += length
            continue

        high = status & 0xF0
        channel = status & 0x0F
        data_count = 1 if high in (0xC0, 0xD0) else 2
        payload = body[index:index + data_count]
        index += data_count
        if len(payload) < data_count:
            break

        if high == 0x90 and payload[1] > 0:
            open_notes[(channel, payload[0])] = (tick, payload[1])
        elif high == 0x80 or (high == 0x90 and payload[1] == 0):
            key = (channel, payload[0])
            if key in open_notes:
                start, velocity = open_notes.pop(key)
                if tick > start:
                    notes.append([payload[0], start / float(division),
                                  (tick - start) / float(division), velocity])

    # 没关掉的音符（有些导出器会漏）：按轨尾收掉，别丢
    for (_channel, pitch), (start, velocity) in open_notes.items():
        if tick > start:
            notes.append([pitch, start / float(division),
                          (tick - start) / float(division), velocity])

    notes.sort(key=lambda n: (n[1], n[0]))
    return name, notes


def send_midi(path, args):
    """把一份 MIDI 摊成 JSON、交给桥去建轨。"""
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        return {"ok": False, "error": "找不到那一份 MIDI：%s" % os.path.basename(path)}
    try:
        tracks = parse_midi(path)
    except Exception as error:
        return {"ok": False, "error": "读不了这份 MIDI：%s" % error}
    if not tracks:
        return {"ok": False, "error": "这份 MIDI 里没有音符"}

    span = 0.0
    for _name, notes in tracks:
        for note in notes:
            span = max(span, note[1] + note[2])
    payload_tracks = [{"name": name, "notes": notes} for name, notes in tracks]

    handle = tempfile.NamedTemporaryFile("w", suffix=".json",
                                         prefix="mysongwriter-midi-",
                                         delete=False, encoding="utf-8")
    try:
        json.dump({"spanBeats": span, "tracks": payload_tracks},
                  handle, ensure_ascii=False)
        handle.close()
        return send({"id": 1, "cmd": "import_midi",
                     "notesPath": handle.name,
                     "at_bar": args.at_bar or 1,
                     "name": args.title or ""})
    finally:
        try:
            os.unlink(handle.name)
        except Exception:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", nargs="?", help="My Songwriter 的产物目录")
    parser.add_argument("--audio")
    parser.add_argument("--midi", help="送一份 MIDI（每条源轨在 Live 里建一条 MIDI 轨）")
    parser.add_argument("--title")
    parser.add_argument("--track", default="AI 草稿")
    parser.add_argument("--slot", type=int, default=0,
                        help="Session 模式下的起始槽（配合 --session）")
    parser.add_argument("--session", action="store_true",
                        help="旧行为：放进 Session 槽，不摆到编曲视图")
    parser.add_argument("--at-bar", type=int, default=None,
                        help="编曲视图里从第几小节开始（默认接在末尾／空轨从第 1 小节）")
    parser.add_argument("--clear", action="store_true",
                        help="先把「AI 草稿」轨在编曲里的旧 clip 清空再放")
    parser.add_argument("--json", action="store_true", help="只打 JSON")
    args = parser.parse_args(argv)

    if args.midi:
        resp = send_midi(args.midi, args)
        if args.json:
            print(json.dumps(resp, ensure_ascii=False))
            return 0 if resp.get("ok") else 1
        if not resp.get("ok"):
            print(resp.get("error") or json.dumps(resp, ensure_ascii=False))
            return 1
        result = resp.get("result") or {}
        names = [t.get("track") or "" for t in (result.get("tracks") or [])]
        detail = ("（%s）" % "、".join(names)) if names else ""
        print("已放进编曲视图：从第 %s 小节起，%d 条 MIDI 轨%s"
              % (_bar_text(result.get("start_bar")), len(names), detail))
        return 0

    folder = args.folder
    params = {}
    if folder:
        folder = os.path.abspath(folder)
        params = load_params(folder)

    audio = args.audio or (pick_audio(folder) if folder else None)
    if not audio:
        parser.error("没有音频文件：给一个产物目录，或者用 --audio")
    audio = os.path.abspath(audio)

    title = args.title or params.get("title") or \
        os.path.splitext(os.path.basename(audio))[0]

    payload = {
        "id": 1,
        "cmd": "import_audio",
        "path": audio,
        "track": args.track,
        "name": title,
        "slot": args.slot,
        "destination": "session" if args.session else "arrangement",
        "clear": bool(args.clear),
    }
    if args.at_bar is not None:
        payload["at_bar"] = int(args.at_bar)

    # ★ 2026-10-18：Live 的 API 建出来的 clip 不会自己做速度分析，
    #   所以"让它测"这条在送进来时是拿不到数的。发送端先量一个一起发过去，
    #   桥照样只在**空工程**里写（工程里有东西就只回报）。
    bpm = detect_bpm(audio)
    if bpm:
        payload["bpm"] = bpm

    resp = send(payload)
    if args.json:
        print(json.dumps(resp, ensure_ascii=False))
        return 0 if resp.get("ok") else 1

    if not resp.get("ok"):
        print(json.dumps(resp, ensure_ascii=False, indent=2))
        return 1

    result = resp.get("result") or {}
    if result.get("destination") == "arrangement" and result.get("clips"):
        clips = result.get("clips") or []
        print("已放进编曲视图：「%s」轨，从第 %s 小节开始。"
              % (result.get("track") or args.track,
                 _bar_text(clips[0].get("bar", result.get("start_bar")))))
        for i, clip in enumerate(clips, 1):
            print("  %2d. %-12s 第 %s 小节" %
                  (i, clip.get("name") or "", _bar_text(clip.get("bar"))))
        note = result.get("tempo_note") or {}
        if note.get("code") == "tempo_from_live":
            print("（Live 测出这首歌是 %s，工程节拍器已经写成这个值）"
                  % _num(note.get("bpm")))
        elif note.get("code") == "tempo_unchanged":
            print("（Live 测出的速度 %s，和工程一样）" % _num(note.get("bpm")))
        elif note.get("code") == "tempo_mismatch":
            print("⚠️ 工程速度是 %s，Live 测出这首歌是 %s —— 现在这样放会跟着"
                  "工程速度变形。要原速听，先把工程速度调成 %s。"
                  % (_num(note.get("project")), _num(note.get("live")),
                     _num(note.get("live"))))
    else:
        print(json.dumps(resp, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
