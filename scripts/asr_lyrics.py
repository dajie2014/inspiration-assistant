#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用本机听写把一首歌里**唱出来的词**抓成文本，供 attach_lyrics.py 贴进谱子。

**为什么需要它**：YuE2 在歌词框空着的时候会自己编词唱（2026-10-18 实测），
那段词只活在音频里，谱子上没有（`w:` 行 0 条、`<lyric>` 0 处）。
用户 2026-10-18 要的是：转 MusicXML 的时候，让它顺手把唱的词也认出来写进谱子。

**它做什么**：把音频丢给本机 VoiceStudio（`http://127.0.0.1:3900/transcribe`），
用 accurate 模式（faster-whisper）拿文字，原样打到 stdout。
不做任何"整理"——整理是 attach_lyrics 的事。

**只对中文歌采用**：attach_lyrics 是按"一个字一个音符位"贴的。
中文一字一音，贴出来能看；英文会被拆成字母逐个贴（实测：
`I 'm _ no t _ b os s`），等于拼字游戏。
⇒ 文本里**没有中文字符时退出码 10**，调用方据此跳过，别往谱子里塞乱码。

用法：
    asr_lyrics.py <音频文件> [--mode fast|accurate]

退出码：
    0  拿到中文，文本已打到 stdout
    10 文本里没有中文（英文/其它语言），调用方应跳过
    2  参数不对
    3  听写服务连不上或失败
"""
import json
import os
import re
import subprocess
import sys

ENDPOINT = os.environ.get("ASR_ENDPOINT", "http://127.0.0.1:3900/transcribe")
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.stderr.write(__doc__)
        return 2
    audio = args[0]
    mode = "accurate"
    if "--mode" in args:
        i = args.index("--mode")
        if i + 1 < len(args):
            mode = args[i + 1]

    if not os.path.isfile(audio):
        sys.stderr.write(f"找不到音频：{audio}\n")
        return 2

    # curl 的 -F 里，文件名要带引号才能容忍路径中的空格和中文
    form = f'audio=@"{audio}"'
    try:
        proc = subprocess.run(
            ["/usr/bin/curl", "-sS", "--max-time", "600", "-X", "POST", ENDPOINT,
             "-F", form, "-F", f"mode={mode}"],
            capture_output=True, text=True, timeout=660,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write("听写超时\n")
        return 3
    if proc.returncode != 0:
        sys.stderr.write(f"听写服务调用失败：{proc.stderr.strip()[:300]}\n")
        return 3
    try:
        data = json.loads(proc.stdout)
    except Exception:
        sys.stderr.write(f"听写没返回 JSON：{proc.stdout[:300]}\n")
        return 3

    text = (data.get("text") or "").strip()
    # 有的引擎只给 segments
    if not text:
        text = " ".join(
            (s.get("text") or "").strip()
            for s in (data.get("segments") or [])
            if isinstance(s, dict)
        ).strip()
    if not text:
        sys.stderr.write("听写没听出词来\n")
        return 3

    if not CJK.search(text):
        sys.stderr.write(f"听出来的是非中文（{data.get('language') or '?'}），不贴：{text[:120]}\n")
        return 10

    # 分段（有就按段、每段一行；attach_lyrics 读纯文本第一段即可，换行不影响）
    segs = [s for s in (data.get("segments") or []) if isinstance(s, dict) and (s.get("text") or "").strip()]
    if len(segs) > 1 and all(CJK.search(s["text"]) for s in segs):
        print("\n".join(s["text"].strip() for s in segs))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
