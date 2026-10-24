#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给"送 Live"的两条路共用：本地算一个 BPM。

抽成单独模块的原因：`ace_to_live.py` 和 `push_to_live.py` 都要用它，
而它们之间互相 import 会成环。这里只放"怎么算"，不碰网络与桥。

⚠️ 算 BPM 要 numpy —— 借本机现成的 venv（见 `BPM_PYTHONS`）；
一个都找不到时返回 None（只是少一个数，不影响送进 Live）。
"""
import os
import subprocess

BPM_PYTHONS = [
    os.path.expanduser(
        "~/Documents/deepseek-harness/default-workspace/yue2-local/mlx-Yue/.venv/bin/python"),
    os.path.expanduser("~/Projects/VoiceStudio/.venv/bin/python"),
]


def detect_bpm(path):
    """返回 BPM（float）或 None。"""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "detect_bpm.py")
    for py in BPM_PYTHONS:
        if not os.path.isfile(py):
            continue
        try:
            proc = subprocess.run([py, script, path], capture_output=True,
                                  text=True, timeout=180)
        except Exception:
            continue
        if proc.returncode == 0:
            try:
                return float(proc.stdout.strip())
            except Exception:
                return None
        return None
    return None
