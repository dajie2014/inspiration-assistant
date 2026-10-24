#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把歌词里的中文结构标记，换成 ACE-Step（灵感助手）认的英文方括号标记。

豆包写词时爱带【主歌1】【预副歌】这类中文段标，直接丢给唱歌引擎会被当歌词唱出来。
这个脚本只动「整行就是一个段标」的行，歌词正文一个字不碰。

默认用法（最省事）：
    复制歌词 → 双击「把段标转成英文.command」→ 回灵感助手粘贴

命令行：
    python3 fix_section_tags.py                # 读剪贴板、转好、写回剪贴板
    python3 fix_section_tags.py --stdout       # 读剪贴板，只打印，不动剪贴板
    python3 fix_section_tags.py 歌词.txt        # 读文件，打印转好的结果
    python3 fix_section_tags.py 歌词.txt --copy # 读文件，转好写回剪贴板
"""

import re
import subprocess
import sys

# 中文数字 → 阿拉伯数字（编号够用就行；超过十的段号很少见）
CJK_NUM = {
    "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
    "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
}

# (中文写法, 英文标记, 要不要保留末尾编号)
# 依据：ACE-Step 官方教程里列出的结构标记
#   [Intro] [Verse] / [Verse 1] [Pre-Chorus] [Chorus] [Bridge] [Outro]
# 另加 [Instrumental]（官方样例里用来标纯器乐段）。
ALIASES = [
    (("前奏", "引子", "序曲", "开场"), "Intro", False),
    (("预副歌", "导歌", "副歌前"), "Pre-Chorus", False),
    (("主歌", "正歌"), "Verse", True),
    (("副歌", "叠句"), "Chorus", False),
    (("桥段", "过桥", "过渡段", "桥"), "Bridge", False),
    (("尾句", "结尾", "尾声", "尾奏", "收尾", "结束"), "Outro", False),
    (("间奏", "器乐间奏", "乐器间奏"), "Instrumental", False),
]

_OPEN = "【[（(｛{"
_CLOSE = "】]）)｝}"

# 整行匹配：允许前面挂 markdown 井号 / 列表符号 / 「1.」这种序号，
# 中间是可选的括号包着段标，后面可跟冒号。正文行不会被当成段标。
LINE_RE = re.compile(
    r"^\s*"
    r"(?:\d{1,2}[.、．)]\s*)?"
    r"[#>*•·\-–—]*\s*"
    r"[" + re.escape(_OPEN) + r"]?\s*"
    r"([^" + re.escape(_OPEN + _CLOSE) + r"]{1,24}?)"
    r"\s*[" + re.escape(_CLOSE) + r"]?\s*[：:]?\s*$"
)


def _number(text):
    """把后缀变成编号：'1'→'1'，'一'→'1'，'A'→'A'；认不出返回 None。"""
    text = text.strip().strip(".．、")
    if text.isdigit():
        return text
    if text in CJK_NUM:
        return str(CJK_NUM[text])
    if len(text) == 1 and text.isascii() and text.isalpha():
        return text.upper()
    return None


def convert_line(line):
    """只转「整行就是段标」的行；别的行原样返回。"""
    m = LINE_RE.match(line)
    if not m:
        return line
    inner = m.group(1).strip()
    if not inner:
        return line

    for names, tag, keep_number in ALIASES:
        for name in names:
            if not inner.startswith(name):
                continue
            rest = inner[len(name):].strip()
            if rest == "":
                return "[%s]" % tag
            num = _number(rest)
            if num is not None:
                if keep_number:
                    return "[%s %s]" % (tag, num)
                return "[%s]" % tag
    return line


def convert_text(text):
    return "\n".join(convert_line(ln) for ln in text.splitlines())


def main():
    argv = sys.argv[1:]
    flags = set(a for a in argv if a.startswith("--"))
    files = [a for a in argv if not a.startswith("--")]

    if files:
        with open(files[0], "r", encoding="utf-8") as f:
            text = f.read()
    else:
        text = subprocess.run(["pbpaste"], capture_output=True).stdout.decode("utf-8")

    out = convert_text(text)

    if "--stdout" in flags or (files and "--copy" not in flags):
        print(out)
    else:
        subprocess.run(["pbcopy"], input=out.encode("utf-8"))
        print(out)

    return 0


if __name__ == "__main__":
    sys.exit(main())
