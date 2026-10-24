#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Live → ACE Studio 的桥：把你**在 Live 里选中的那个 clip** 送进 ACE。

**为什么需要它**：Live 里分完轨、或者转成 MIDI 之后，下一步往往是想让
虚拟歌手唱。到这一步现在只能"在 Live 里导出、再去 ACE 里导入"手动搬。
这个脚本把那一搬接上：

  · 选中的是**音频 clip** → 按 clip 的起止裁成 wav → `acestudio-cli import`；
  · 选中的是**MIDI clip** → 写成 .mid → `acestudio-cli import`。

**边界（先说清楚）**：
  · 它**不改 Live 的工程**，只读选中的 clip（Live 那边只多了一个只读命令）。
  · 它**不改 ACE 的工程设置**，只是调官方的 `import` 把文件放进去；
    落第几条轨、什么乐器，进了 ACE 再由你定。
  · 音频裁切按 clip 的起止时间算。**warp 打开、而且速度跟工程不一致时**
    可能会偏一点 —— 这种时候宁可先在 Live 里把那段"合并/导出"，别硬用。

用法：
    live_to_ace.py                 # 送选中的那个 clip
    live_to_ace.py --dry-run       # 只准备文件、不往 ACE 放
    live_to_ace.py --pos 0         # 放到时间轴 0（秒；不给就由 ACE 自己摆）

前提：Live 开着（桥在跑）、ACE Studio 开着（External Agent Access 已开）。
"""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile

ACE_CLI = "/Applications/ACE Studio.app/Contents/Helpers/acestudio-cli"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
PORT_FILE = os.path.join(tempfile.gettempdir(), "mysongwriter-live.port")


def ask_live(msg, timeout=5.0):
    """给 Live 桥发一条 UDP，拿回 result（失败抛异常）。"""
    try:
        port = int(open(PORT_FILE).read().strip())
    except Exception:
        raise RuntimeError("Live 桥没在跑（找不到端口文件）。先把 Live 打开、确认控制面已加载。")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    payload = dict(msg, id=1)
    sock.sendto(json.dumps(payload).encode("utf-8"), ("127.0.0.1", port))
    try:
        data, _ = sock.recvfrom(8 * 1024 * 1024)
    except socket.timeout:
        raise RuntimeError("Live 没回话（桥在，可能正忙）。")
    finally:
        sock.close()
    resp = json.loads(data.decode("utf-8"))
    if not resp.get("ok"):
        raise RuntimeError("Live 说不行：" + str(resp.get("error")))
    return resp.get("result")


def varint(n):
    out = bytearray([n & 0x7F])
    n >>= 7
    while n:
        out.append(0x80 | (n & 0x7F))
        n >>= 7
    return bytes(reversed(out))


def write_midi(path, notes, tempo_bpm, division=480):
    """把 Live 给的音符写成标准 MIDI（Type 1，单轨）。

    `notes` 里每个：pitch / start（beats）/ dur（beats）/ vel。
    """
    events = []  # (tick, order, bytes)  —— order 让同一 tick 上 off 先于 on
    for n in notes:
        start = max(0.0, float(n.get("start", 0)))
        dur = max(0.0, float(n.get("dur", 0)))
        pitch = int(n.get("pitch", 60)) & 0x7F
        vel = max(1, min(127, int(n.get("vel", 100))))
        on = int(round(start * division))
        off = int(round((start + dur) * division))
        events.append((on, 1, bytes([0x90, pitch, vel])))
        events.append((off, 0, bytes([0x80, pitch, 0])))
    events.sort(key=lambda e: (e[0], e[1]))

    track = bytearray()
    # 速度（微秒/四分音符）
    us = int(round(60_000_000 / max(1.0, float(tempo_bpm))))
    track += varint(0) + b"\xFF\x51\x03" + us.to_bytes(3, "big")
    last = 0
    for tick, _, data in events:
        track += varint(tick - last) + data
        last = tick
    track += varint(0) + b"\xFF\x2F\x00"   # End of Track

    header = b"MThd" + struct.pack(">IHHH", 6, 1, 1, division)
    with open(path, "wb") as f:
        f.write(header + b"MTrk" + struct.pack(">I", len(track)) + bytes(track))


def export_audio(clip, out_path):
    """按 clip 的起止把源文件裁出来。单位坑：start_time=beats、end_time=秒。"""
    src = clip.get("file_path") or ""
    if not src or not os.path.isfile(src):
        raise RuntimeError("这个 audio clip 没给出源文件路径（可能是冻结/采样的 clip）。")
    tempo = float(clip.get("tempo") or 120.0)
    start_sec = float(clip.get("start_time") or 0.0) * 60.0 / max(1.0, tempo)
    end_sec = float(clip.get("end_time") or 0.0)
    dur = max(0.05, end_sec - start_sec)
    cmd = [FFMPEG, "-y", "-v", "error", "-i", src,
           "-ss", f"{start_sec:.4f}", "-t", f"{dur:.4f}",
           "-acodec", "pcm_s16le", "-ar", "48000", "-ac", "2", out_path]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("裁音频没成：" + (proc.stderr or "").strip()[:300])
    return {"kind": "audio", "seconds": round(dur, 2), "start_sec": round(start_sec, 2)}


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    pos = None
    if "--pos" in args:
        i = args.index("--pos")
        if i + 1 < len(args):
            pos = args[i + 1]

    clip = ask_live({"cmd": "selected"})
    if not clip.get("name"):
        raise SystemExit("Live 里现在没有选中的 clip —— 先点一下要送的那一个。")

    tmpdir = tempfile.mkdtemp(prefix="live-to-ace-")
    stem = "".join(c for c in (clip.get("name") or "clip") if c not in "/:").strip() or "clip"

    if clip.get("is_audio"):
        out = os.path.join(tmpdir, stem + ".wav")
        info = export_audio(clip, out)
    else:
        notes = clip.get("notes") or []
        if not notes:
            raise SystemExit("选中的 MIDI clip 里没有音符。")
        out = os.path.join(tmpdir, stem + ".mid")
        write_midi(out, notes, float(clip.get("tempo") or 120.0))
        info = {"kind": "midi", "notes": len(notes)}

    print(f"准备好了：{info}")
    print(f"文件：{out}")
    if dry:
        print("--dry-run：没有往 ACE 放。")
        return 0

    if not os.path.isfile(ACE_CLI):
        raise SystemExit("找不到 acestudio-cli —— ACE Studio 装在哪？")

    cmd = [ACE_CLI, "import", "file", "--path", out]
    if pos is not None:
        cmd += ["--pos", pos]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-800:])
        print(proc.stderr[-800:], file=sys.stderr)
        raise SystemExit("ACE 没接住这个文件（上面是它的原话）。")
    print(proc.stdout.strip()[:1200])
    print("已送进 ACE。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
