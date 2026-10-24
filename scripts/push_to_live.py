#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 My Songwriter 的一首歌送进 Ableton Live。

**这条线只送音频，不碰乐谱。**
（用户 2026-10-18 定：Live 是循环汲取灵感的大工具，跟它打交道不需要
MusicXML；谱子只在往 ACE Studio 送的时候才用。）

用法：
    push_to_live.py "<产物目录>"
    push_to_live.py --audio 歌.flac --title 歌名 --track "AI 草稿"

默认落点是**编曲视图**：接在这条轨已有内容末尾（空轨从第 1 小节），
不覆盖任何东西；`--clear` 先清空、`--at-bar N` 指定小节、
`--session` 放回 Session 的格子。

**速度不在这里算** —— 桥会让 Live 自己测速，再把工程节拍器写成它测出的值。
"""
import argparse
import json
import os
import socket
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


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", nargs="?", help="My Songwriter 的产物目录")
    parser.add_argument("--audio")
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
