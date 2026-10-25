#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""谱面工作室改完谱 → 交给灵感助手，开一轮新的生成。

用户 2026-10-25：
「修改完乐谱之后，重新唱一遍。就自动触发一轮新的生成，在主程序当中写一个 script。」

**为什么不在工作室里自己跑**：主程序那一轮带着进度条、历史、送 ACE/Live、
LoRA 和内存闸；工作室只负责「改谱」，唱归主程序。

**通道**：`~/Library/Application Support/Composer Bridge/regenerate.json`
—— 跟风格/歌词同一只信箱（Swift 那边叫 `BridgeInbox`）。主程序在启动、
窗口被激活、收到分布式通知时各读一次；这里写完再 `open -a 灵感助手`
把窗口叫到前面，就等于按下了「生成」。

用法：
    studio_handoff.py --abc-file 改后.abc --style "…" --lyrics "…" \\
                      --seed 42 --steps 8 --title "歌名"

输出一行 JSON：{"ok": true, "message": "已交给灵感助手（… 字节的谱）"}
"""
import argparse
import json
import os
import subprocess
import sys
import time

BRIDGE = os.path.join(os.path.expanduser("~"), "Library",
                      "Application Support", "Composer Bridge")
TARGET = os.path.join(BRIDGE, "regenerate.json")
APP = "灵感助手"


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--abc-file", required=True, help="改好的 ABC 谱")
    parser.add_argument("--style", default="")
    parser.add_argument("--lyrics", default="")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--title", default="")
    parser.add_argument("--no-open", action="store_true",
                        help="只写信、不把主程序叫到前面（测试用）")
    parser.add_argument("--bridge-dir", default="",
                        help="信箱目录（测试用；默认 ~/Library/Application Support/Composer Bridge）")
    args = parser.parse_args()

    path = os.path.abspath(os.path.expanduser(args.abc_file))
    try:
        with open(path, encoding="utf-8") as handle:
            abc = handle.read()
    except OSError as error:
        print(json.dumps({"ok": False, "message": "读不了那份谱：%s" % error},
                         ensure_ascii=False))
        return 1
    if not abc.strip():
        print(json.dumps({"ok": False, "message": "谱子是空的"}, ensure_ascii=False))
        return 1

    payload = {
        "from": "yue2-studio",
        "abc": abc,
        "style": args.style,
        "lyrics": args.lyrics,
        "steps": args.steps,
        "title": args.title,
        "at": time.time(),
    }
    if args.seed is not None:
        payload["seed"] = args.seed

    bridge = (os.path.abspath(os.path.expanduser(args.bridge_dir))
              if args.bridge_dir else BRIDGE)
    target = os.path.join(bridge, "regenerate.json")

    os.makedirs(bridge, exist_ok=True)
    # ★ 先写临时文件再 rename：主程序可能在任意时刻读，半截 JSON 会被当成坏信丢掉。
    temporary = target + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
    os.replace(temporary, target)

    if not args.no_open:
        try:
            subprocess.run(["open", "-a", APP], check=False, timeout=10)
        except Exception:
            # 叫不醒也只是界面不跳 —— 信已经写好了，切一下窗口照样会读。
            pass

    print(json.dumps({"ok": True,
                      "message": "已交给灵感助手（%d 字节的谱）" % len(abc)},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
