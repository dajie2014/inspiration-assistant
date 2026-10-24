#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地测一个音频文件的速度（BPM）。给「ACE → Live」那座桥用。

**为什么自己测**：2026-10-18 实测——Live 的 API 建出来的 audio clip **不会
自动做速度分析**（`warp_markers` 一直是空的），所以桥里那套"建探针让 Live 测"
在 API 导入这条路上拿不到数（返回的 tempo_note 是 null）。用户要的是"进来的
音频要有速度"，那就自己测一个。

**怎么测**：ffmpeg 解成单声道 → 算能量包络 → 自相关找节拍周期。
不追求学术精度：拿到的是"这首歌大概多少拍"，跟 Live 自己测的差个零点几
很正常。真要精确，还是得在 Live 里手动让它分析一次。

用法：
    detect_bpm.py <音频> [--min 60] [--max 200]
输出：一行数字（BPM，保留一位小数）；测不出来就退出码 2。

⚠️ 需要 numpy —— 用带 numpy 的解释器跑（本机：mlx-Yue 或 VoiceStudio 的 venv）。
"""
import subprocess
import sys

import numpy as np

FFMPEG = "/opt/homebrew/bin/ffmpeg"
SR = 22050
FRAME = 1024
HOP = 512


def load_mono(path):
    proc = subprocess.run(
        [FFMPEG, "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR),
         "-f", "f32le", "-"],
        capture_output=True)
    if proc.returncode != 0 or not proc.stdout:
        raise RuntimeError("ffmpeg 解码失败")
    return np.frombuffer(proc.stdout, dtype=np.float32)


def detect(path, lo_bpm=60.0, hi_bpm=200.0):
    x = load_mono(path)
    if len(x) < SR * 3:
        raise RuntimeError("太短了（不到 3 秒）")
    frames = (len(x) - FRAME) // HOP
    if frames < 8:
        raise RuntimeError("太短了")
    # 能量包络（RMS）
    idx = np.arange(frames) * HOP
    env = np.empty(frames, dtype=np.float32)
    for i, start in enumerate(idx):
        seg = x[start:start + FRAME]
        env[i] = np.sqrt(np.mean(seg * seg))
    env = env - env.mean()
    if not np.any(env):
        raise RuntimeError("没有能量起伏")

    # 自相关（FFT 版，快）
    n = 1 << int(np.ceil(np.log2(2 * frames)))
    spec = np.fft.rfft(env, n)
    ac = np.fft.irfft(spec * np.conj(spec), n)[:frames]
    if ac[0] <= 0:
        raise RuntimeError("能量太平")
    ac = ac / ac[0]

    fps = SR / HOP
    # 允许的间隔：0.25s（240 BPM）到 1.2s（50 BPM）
    lo_lag = int(np.floor(fps * 60.0 / hi_bpm))
    hi_lag = int(np.ceil(fps * 60.0 / lo_bpm))
    lo_lag = max(2, lo_lag)
    hi_lag = min(frames - 2, hi_lag)
    if hi_lag <= lo_lag:
        raise RuntimeError("音频太短，测不出")
    seg = ac[lo_lag:hi_lag]
    lag = lo_lag + int(np.argmax(seg))
    peak = float(ac[lag])
    if peak < 0.08:
        raise RuntimeError("节拍不明显（峰值 %.3f）" % peak)

    bpm = 60.0 * fps / lag
    # 折到常用区间：太慢的翻一倍，太快的减半（流行乐 70~180）
    while bpm < 70.0:
        bpm *= 2.0
    while bpm > 180.0:
        bpm /= 2.0
    return bpm, peak


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.stderr.write(__doc__)
        return 2
    lo, hi = 60.0, 200.0
    if "--min" in sys.argv:
        lo = float(sys.argv[sys.argv.index("--min") + 1])
    if "--max" in sys.argv:
        hi = float(sys.argv[sys.argv.index("--max") + 1])
    try:
        bpm, peak = detect(args[0], lo, hi)
    except Exception as exc:
        sys.stderr.write("测速失败：%s\n" % exc)
        return 2
    print("%.1f" % bpm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
