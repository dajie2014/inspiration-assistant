#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ACE → Live 的桥：把 **ACE 里选中的轨**（或整首混音）渲染出来，送进 Live 的编曲视图。

**为什么需要它**：用户在 Live 里分轨不要钱（2026-10-18 他原话），所以
"ACE 里唱/做好的一段 → 拿回 Live 分轨、循环、编曲"是常走的一条路。
以前这一步是手动导出再拖进去，现在一条命令。

**它做什么**：
  1. `acestudio-cli export audio --scope <范围> --wait` 渲染到临时目录；
  2. 把渲染出来的每个 wav 用 Live 桥的 `import_audio` 摆进编曲视图（默认接在
     「来自 ACE」这条轨的末尾，空轨从第 1 小节）。

**范围**（`--scope`，名字与 ACE 导出对话框一致）：
  · `selected-tracks`（默认）—— 你在 ACE 里选中的轨，**一轨一个文件**；
  · `all-tracks` —— 所有轨各一个文件；
  · `master` —— 整首混音成一个文件。

前提：ACE Studio 开着（External Agent Access 已开）、Live 开着（桥已加载）。
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from push_to_live import send  # 复用 Live 客户端（端口文件、重试、超时都在里面）

ACE_CLI = "/Applications/ACE Studio.app/Contents/Helpers/acestudio-cli"

from bpm import detect_bpm  # noqa: E402  （同一个文件夹；算 BPM 的实现放 bpm.py）


def ace_selected_bpms():
    """读 ACE 自己给选中轨上第一条音频 clip 测出来的 BPM。

    用户 2026-10-18 提醒：音频放进 ACE 后，**尾部会显示 BPM**（ACE 自己分析的）。
    CLI 里对应 `clip beat-content` —— 那条数据随 clip 存进工程，导进来就有，
    不用自己再算。比本地能量包络准，所以优先用它。
    """
    import re
    try:
        sel = subprocess.run([ACE_CLI, "selection", "get"], capture_output=True,
                             text=True, timeout=30)
    except Exception:
        return {}
    idxs = [int(x) for x in re.findall(r"arrangement (\d+)", sel.stdout or "")]
    out = {}
    for i in idxs:
        try:
            r = subprocess.run(
                [ACE_CLI, "clip", "beat-content",
                 "--track-index", str(i), "--clip-index", "0"],
                capture_output=True, text=True, timeout=60)
        except Exception:
            continue
        m = re.search(r"([\d.]+)\s*BPM", r.stdout or "")
        if m:
            try:
                out[i] = float(m.group(1))
            except Exception:
                pass
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="把 ACE 里的音频送进 Live")
    ap.add_argument("--scope", default="selected-tracks",
                    choices=["selected-tracks", "all-tracks", "master"])
    ap.add_argument("--track", default="来自 ACE", help="Live 里落到哪条轨（没有就新建）")
    ap.add_argument("--from", dest="frm", default=None, help="只导这一段（ACE 的时间写法）")
    ap.add_argument("--to", dest="to", default=None)
    ap.add_argument("--dry-run", action="store_true", help="只导出，不往 Live 送")
    args = ap.parse_args(argv)

    if not os.path.isfile(ACE_CLI):
        print("找不到 acestudio-cli（ACE Studio 装在哪？）", file=sys.stderr)
        return 2

    tmp = tempfile.mkdtemp(prefix="ace-to-live-")
    base = os.path.join(tmp, "ace-export.wav")
    cmd = [ACE_CLI, "export", "audio", "--path", base, "--scope", args.scope, "--wait"]
    if args.frm:
        cmd += ["--from", args.frm]
    if args.to:
        cmd += ["--to", args.to]
    # ★ 先用 ACE 自己测的速度（音频尾部那个值），拿不到再本地算
    ace_bpms = ace_selected_bpms()
    ace_bpm = None
    if ace_bpms:
        ace_bpm = list(ace_bpms.values())[0]
        print("ACE 测出来的速度：%s BPM" % ace_bpm)

    print("正在让 ACE 渲染…（选中轨多的话要一会儿）")
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        print("ACE 没渲染成：" + (detail[-600:] or f"退出码 {proc.returncode}"), file=sys.stderr)
        return 3

    files = sorted(glob.glob(os.path.join(tmp, "*.wav")))
    # master 那条可能就叫 base 的名字；per-track 会在 basename 上追加轨名
    if not files:
        print("ACE 说渲染好了，但临时目录里没有 wav。", file=sys.stderr)
        return 4
    print(f"渲染出 {len(files)} 个文件。")

    if args.dry_run:
        for f in files:
            print("  " + f)
        print("--dry-run：没有往 Live 送。")
        return 0

    ok = 0
    for f in files:
        name = os.path.splitext(os.path.basename(f))[0]
        bpm = ace_bpm or detect_bpm(f)
        payload = {"id": 1, "cmd": "import_audio", "path": f,
                   "track": args.track, "name": name,
                   "destination": "arrangement"}
        if bpm:
            payload["bpm"] = bpm
        try:
            resp = send(payload)
        except Exception as exc:
            print(f"送不进 Live：{name}（{exc}）", file=sys.stderr)
            continue
        if resp.get("ok"):
            ok += 1
            res = resp.get("result") or {}
            clips = res.get("clips") or []
            where = clips[0].get("bar") if clips else "?"
            print(f"进了 Live：{name} → 「{res.get('track')}」第 {where} 小节")
        else:
            print(f"Live 拒了：{name}（{resp.get('error')}）", file=sys.stderr)

    if ok == 0:
        return 5
    print(f"完成：{ok}/{len(files)} 个文件进了 Live。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
